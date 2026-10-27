// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "replicate/api.h"
#include "main_context/api.h"
#include "network/api.h"
#include "core/log.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/os.h"
#include "interface/packet_stream.h"
#include "lua_bindings/tree_depth.h"
#include <algorithm>
#include "interface/magic_event.h"
#include <Object.h>
#include <Context.h>
#include <Engine.h>
#include <Variant.h>
#include <Scene.h>
#include <ResourceCache.h>
#include <CoreEvents.h>
#include <SceneEvents.h>
#include <ReplicationState.h>
#include <Component.h>
#include <cereal/archives/portable_binary.hpp>
#include <cereal/types/vector.hpp>
#include <cereal/types/tuple.hpp>
#define MODULE "replicate"

using interface::Event;
namespace magic = Urho3D;
using magic::Node;
using magic::Scene;
using magic::Component;

namespace replicate {

static ss_ buf_to_string(const magic::VectorBuffer &buf)
{
	return ss_((const char*)&buf.GetBuffer().Front(), buf.GetBuffer().Size());
}

struct PeerState
{
	PeerId peer_id = 0;
	main_context::SceneReference scene_ref = nullptr;
	magic::SceneReplicationState scene_state;
};

struct Module: public interface::Module, public replicate::Interface
{
	interface::Server *m_server;
	// NOTE: We use pointers to SceneReplicationStates as Connection pointers in
	//       other replication states in order to scene->CleanupConnection()
	//       without an actual Connection object (which we don't want to use)
	sm_<PeerId, PeerState> m_peers;


	// Per scene: which nodes a peer gets. Empty means every node, which is
	// what every scene did before there was a filter.
	sm_<main_context::SceneReference,
			std::function<bool(PeerId, uint)>> m_node_filters;
	// Per scene: which of a peer's dirty nodes go first; see
	// set_node_priority()
	sm_<main_context::SceneReference,
			std::function<float(PeerId, uint)>> m_node_priorities;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server)
	{
		log_d(MODULE, "replicate construct");
	}

	~Module()
	{
		log_d(MODULE, "replicate destruct");
		main_context::access(m_server, [&](main_context::Interface *imc){
			for(auto &pair: m_peers){
				PeerState &ps = pair.second;
				magic::Scene *scene = nullptr;
				if(ps.scene_ref != nullptr){
					scene = imc->find_scene(ps.scene_ref);
					if(!scene)
						log_w(MODULE, "~Module(): Scene %p not found",
								ps.scene_ref);
				}
				if(scene){
					scene->CleanupConnection(
							(magic::Connection*)&ps.scene_state);
				}
				// Make sure to fully clear the SceneReplicationState in
				// the context of main_context. Otherwise race conditions can
				// occur inside NodeReplicationStates due to usage of Urho3D's
				// thread-unsafe weak pointers.
				ps.scene_state.Clear();
			}
		});
	}

	void init()
	{
		log_d(MODULE, "replicate init");
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("core:unload"));
		m_server->sub_event(this, Event::t("core:continue"));
		m_server->sub_event(this, Event::t("network:client_connected"));
		m_server->sub_event(this, Event::t("network:client_disconnected"));
		m_server->sub_event(this, Event::t("core:tick"));
		m_server->sub_event(this, Event::t("main_context:scene_deleted"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_VOIDN("core:unload", on_unload)
		EVENT_VOIDN("core:continue", on_continue)
		EVENT_TYPEN("network:client_connected", on_client_connected,
				network::NewClient)
		EVENT_TYPEN("network:client_disconnected", on_client_disconnected,
				network::OldClient)
		EVENT_TYPEN("core:tick", on_tick, interface::TickEvent)
		EVENT_TYPEN("main_context:scene_deleted", on_scene_deleted,
				main_context::SceneDeleted)
	}

	// [LOCAL_REJOIN] A deleted scene leaves its peers' sync: a module's
	// reload deletes its scene before its peers' disconnects come in, and
	// each tick between said "Scene not found" for each of them
	void on_scene_deleted(const main_context::SceneDeleted &e)
	{
		main_context::access(m_server, [&](main_context::Interface *imc){
			for(auto &pair: m_peers){
				PeerState &ps = pair.second;
				if(ps.scene_ref != e.scene)
					continue;
				ps.scene_state.Clear();
				ps.scene_ref = nullptr;
				log_v(MODULE, "peer %i: its scene %p deleted", ps.peer_id,
						e.scene);
			}
		});
	}

	void on_start()
	{
	}

	void on_unload()
	{
	}

	void on_continue()
	{
	}

	void on_client_connected(const network::NewClient &client_connected)
	{
		log_v(MODULE, "replicate::on_client_connected: id=%zu",
				client_connected.info.id);
	}

	void on_client_disconnected(const network::OldClient &old_client)
	{
		log_v(MODULE, "replicate::on_client_disconnected: id=%zu",
				old_client.info.id);
		auto peer = old_client.info.id;
		auto it = m_peers.find(peer);
		if(it == m_peers.end())
			return;
		PeerState &ps = it->second;
		if(ps.scene_ref){
			main_context::access(m_server, [&](main_context::Interface *imc){
				magic::Scene *scene = imc->find_scene(ps.scene_ref);
				if(!scene){
					log_w(MODULE, "on_client_disconnected(): Scene %p not found",
							ps.scene_ref);
					return;
				}
				// NOTE: We use pointers to SceneReplicationStates as Connection
				//       pointers in other replication states in order to
				//       scene->CleanupConnection() without an actual Connection
				//       object (which we don't want to use)
				scene->CleanupConnection((magic::Connection*)&ps.scene_state);
			});
			m_server->emit_event("replicate:peer_left_scene",
					new PeerLeftScene(peer, ps.scene_ref));
		}
		m_peers.erase(peer);
	}

	void on_tick(const interface::TickEvent &event)
	{
		sync_changes();
	}

	void sync_changes()
	{
		// For a reference implementation of this kind of network
		// synchronization, see Urho3D's Network/Connection.cpp
		//
		// What this costs is what every module that asks replicate for
		// anything waits for, because it runs on replicate's own thread:
		// voxelworld's commit does a replicate::access() per commit and was
		// measured waiting seconds for it. So it says how long it took and
		// over how much when it is slow; see SLOW_SYNC_US below.
		const int64_t t0 = interface::os::time_us();
		size_t n_peers = 0, n_nodes = 0;
		int64_t prepare_us = 0;
		m_collecting_sends = true;

		// Every peer's backlog in one hop, before the pass (see the note
		// at PendingSend on hops)
		sm_<PeerId, size_t> pending;
		network::access(m_server, [&](network::Interface *inetwork){
			for(auto &pair: m_peers)
				pending[pair.first] = inetwork->pending_bytes(pair.first);
		});
		int64_t t_inside = 0;
		main_context::access(m_server, [&](main_context::Interface *imc)
		{
			// Where the time actually goes is the question: getting into
			// main_context, or the walk once inside it
			t_inside = interface::os::time_us();
			// Send changes to each peer (each of which has its own replication
			// state)
			for(auto &pair: m_peers){
				PeerState &ps = pair.second;
				if(ps.scene_ref == nullptr)
					continue;
				magic::Scene *scene = imc->find_scene(ps.scene_ref);
				if(!scene){
					log_w(MODULE, "sync_changes(): Scene %p not found",
							ps.scene_ref);
					continue;
				}
				// Backpressure ([NET_CHANNELS]): a peer with this much
				// already waiting for its socket gets nothing more this
				// tick; its nodes stay dirty and go when it has drained.
				// Over a lossy link the world's chunks were queued as one
				// burst, and everything behind them waited its length.
				static const size_t PEER_BACKLOG_BYTES = 512 * 1024;
				if(pending[ps.peer_id] > PEER_BACKLOG_BYTES){
					// Said once every five seconds a peer is held
					static int64_t said_us = 0;
					if(t0 - said_us > 5000000){
						said_us = t0;
						log_i(MODULE, "peer %i held: %zu bytes queued for it or "
								"unhandled by it, %u nodes dirty", ps.peer_id,
								pending[ps.peer_id],
								ps.scene_state.dirtyNodes_.Size());
					}
					continue;
				}

				// Compare attributes and set replication states dirty as needed;
				// this accesses every replication state for every node.
				// NOTE: This can be called multiple times per scene; only the
				//       first call will do anything as it clears the
				//       marked-for-update lists
				const int64_t t_prepare = interface::os::time_us();
				scene->PrepareNetworkUpdate();
				prepare_us += interface::os::time_us() - t_prepare;

				magic::HashSet<uint> nodes_to_process;
				uint scene_id = scene->GetID();
				nodes_to_process.Insert(scene_id);
				sync_node(ps.peer_id, scene_id, nodes_to_process, scene,
						ps.scene_state);

				nodes_to_process.Insert(ps.scene_state.dirtyNodes_);
				nodes_to_process.Erase(scene_id);

				n_peers++;
				// A budget, because this runs on replicate's own thread and
				// everything that asks replicate for anything waits for it.
				// A peer joining a VoxeLibre world was measured taking 1672
				// nodes and 3.6 seconds in one pass -- the whole world's
				// chunks, each carrying a compressed voxel buffer -- and
				// voxelworld's commit, the luanti module behind it and the
				// game behind that all stopped for the length of it.
				//
				// What is left over stays in dirtyNodes_ and is taken on the
				// next tick, which is what the set is for; the world arrives
				// over a few more ticks and nothing waits seconds.
				//
				// [LOAD_OWN_CHUNK] In the scene's priority order when it has
				// one: a world's chunks nearest the peer first, so that the
				// one it stands in is not somewhere in 40 MB of the rest
				// over a slow link. simplified: a node that is dirty because
				// it *changed* -- a dug voxel -- goes by the same order.
				static const int64_t SYNC_BUDGET_US = 20000;
				sv_<uint> order;
				auto prit = m_node_priorities.find(ps.scene_ref);
				if(prit != m_node_priorities.end()){
					sv_<std::pair<float, uint>> by;
					by.reserve(nodes_to_process.Size());
					for(auto it = nodes_to_process.Begin();
							it != nodes_to_process.End(); ++it)
						by.emplace_back(prit->second(ps.peer_id, *it), *it);
					std::sort(by.begin(), by.end());
					for(auto &x : by)
						order.push_back(x.second);
				}
				size_t next = 0;
				while(!nodes_to_process.Empty()){
					// A node already taken as another's dependency is
					// skipped by sync_node itself
					uint node_id = next < order.size() ? order[next++] :
							nodes_to_process.Front();
					sync_node(ps.peer_id, node_id, nodes_to_process, scene,
							ps.scene_state);
					n_nodes++;
					if((n_nodes & 15) == 0 &&
							interface::os::time_us() - t0 > SYNC_BUDGET_US)
						break;
				}
			}
		});

		m_collecting_sends = false;
		const size_t n_sends = m_pending_sends.size();
		const int64_t t_flush = interface::os::time_us();
		flush_pending_sends();
		const int64_t flush_us = interface::os::time_us() - t_flush;

		static const int64_t SLOW_SYNC_US = 500000;
		const int64_t took = interface::os::time_us() - t0;
		if(took >= SLOW_SYNC_US){
			log_w(MODULE, "sync_changes(): %zu nodes and %zu packets for %zu "
					"peers took %.1f s -- %.1f s of it waiting to get into "
					"main_context, %.1f s comparing every attribute of every "
					"node, %.1f s handing the packets to network",
					n_nodes, n_sends, n_peers, took / 1e6,
					(t_inside - t0) / 1e6, prepare_us / 1e6, flush_us / 1e6);
		}
	}

	// Whether this peer gets this node at all; see set_node_filter()
	bool peer_wants_node(PeerId peer, uint node_id)
	{
		auto peer_it = m_peers.find(peer);
		if(peer_it == m_peers.end())
			return true;
		auto it = m_node_filters.find(peer_it->second.scene_ref);
		if(it == m_node_filters.end() || !it->second)
			return true;
		return it->second(peer, node_id);
	}

	// The peer had this node and should not any more: the packet a deleted
	// node sends, and the replication states taken off the node and its
	// components so that nothing points into the state about to be erased.
	void drop_node_from_peer(PeerId peer, Node *node, uint node_id,
			magic::SceneReplicationState &scene_state)
	{
		log_d(MODULE, "drop_node_from_peer(): peer=%zu, node_id=%zu",
				peer, node_id);
		magic::Connection *conn = (magic::Connection*)&scene_state;
		node->CleanupConnection(conn);
		auto &components = node->GetComponents();
		for(uint i = 0; i < components.Size(); i++)
			components[i]->CleanupConnection(conn);
		magic::VectorBuffer buf;
		buf.WriteNetID(node_id);
		send_to_peer(peer, "replicate:remove_node", buf);
		scene_state.nodeStates_.Erase(node_id);
		scene_state.dirtyNodes_.Erase(node_id);
	}

	// A node and, before it, the dirty nodes it depends on (its parent,
	// and theirs). By a stack of its own ([SERVER_REPLICATE_DEPTH]): a
	// recursion through the dependencies went once per level, and a
	// 100000-node chain met at its bottom -- dirty nodes go in the order
	// they were made -- overflowed replicate's thread's stack.
	void sync_node(PeerId peer,
			uint node_id, magic::HashSet<uint> &nodes_to_process,
			magic::Scene *scene, magic::SceneReplicationState &scene_state)
	{
		if(!nodes_to_process.Erase(node_id))
			return;
		sv_<uint> stack{node_id};
		while(!stack.empty()){
			uint dep = 0;
			if(Node *n = scene->GetNode(stack.back())){
				auto &deps = n->GetDependencyNodes();
				for(auto it = deps.Begin(); it != deps.End(); ++it){
					uint id = (*it)->GetID();
					if(scene_state.dirtyNodes_.Contains(id) &&
							nodes_to_process.Erase(id)){
						dep = id;
						break;
					}
				}
			}
			if(dep){
				stack.push_back(dep);
				continue;
			}
			sync_one_node(peer, stack.back(), scene, scene_state);
			stack.pop_back();
		}
	}

	// One node, its dependencies already synced
	void sync_one_node(PeerId peer, uint node_id,
			magic::Scene *scene, magic::SceneReplicationState &scene_state)
	{
		log_d(MODULE, "sync_node(): node_id=%zu", node_id);
		auto it = scene_state.nodeStates_.Find(node_id);
		if(it == scene_state.nodeStates_.End()){
			// New node
			Node *n = scene->GetNode(node_id);
			if(n){
				// Out of this peer's range: it gets it if it comes into one
				if(!peer_wants_node(peer, node_id)){
					scene_state.dirtyNodes_.Erase(node_id);
					return;
				}
				sync_create_node(peer, n, scene_state);
			} else {
				// Was already deleted
				log_w(MODULE, "New node was already deleted: %zu", node_id);
				scene_state.dirtyNodes_.Erase(node_id);
			}
		} else {
			// Existing node
			magic::NodeReplicationState &node_state = it->second_;
			Node *n = node_state.node_;
			if(!n){
				// Node was removed
				magic::VectorBuffer buf;
				buf.WriteNetID(node_id);
				send_to_peer(peer, "replicate:remove_node", buf);
				scene_state.nodeStates_.Erase(node_id);
				scene_state.dirtyNodes_.Erase(node_id);
			} else if(!peer_wants_node(peer, node_id)){
				drop_node_from_peer(peer, n, node_id, scene_state);
			} else {
				sync_existing_node(peer, n, node_state, scene_state);
			}
		}
	}

	// A node past the client's MAX_TREE_DEPTH, which it refuses: said once
	// simplified: on create only; a node moved that deep is the client's to log
	bool m_deep_logged = false;
	void sync_create_node(PeerId peer, Node *node,
			magic::SceneReplicationState &scene_state)
	{
		log_d(MODULE, "sync_create_node(): %zu", node->GetID());
		if(!m_deep_logged &&
				lua_bindings::tree_depth(node, MAX_TREE_DEPTH) > MAX_TREE_DEPTH){
			m_deep_logged = true;
			log_w(MODULE, "node %u is past %i levels deep: clients refuse it "
					"and the nodes under it; later ones not logged",
					node->GetID(), MAX_TREE_DEPTH);
		}

		magic::NodeReplicationState &node_state =
				scene_state.nodeStates_[node->GetID()];
		node_state.connection_ = (magic::Connection*)&scene_state;
		node_state.sceneState_ = &scene_state;
		node_state.node_ = node;
		node->AddReplicationState(&node_state);

		magic::VectorBuffer buf;
		buf.WriteNetID(node->GetID());
		node->WriteInitialDeltaUpdate(buf, 0);

		// User variables
		auto &vars = node->GetVars();
		buf.WriteVLE(vars.Size());
		for(auto it = vars.Begin(); it != vars.End(); ++it){
			buf.WriteStringHash(it->first_);
			buf.WriteVariant(it->second_);
		}

		// Components
		buf.WriteVLE(node->GetNumNetworkComponents());
		auto &components = node->GetComponents();
		for(uint i = 0; i<components.Size(); i++){
			Component *component = components[i];
			if(component->GetID() >= magic::FIRST_LOCAL_ID)
				continue;
			magic::ComponentReplicationState &component_state =
					node_state.componentStates_[component->GetID()];
			component_state.connection_ = (magic::Connection*)&scene_state;
			component_state.nodeState_ = &node_state;
			component_state.component_ = component;
			component->AddReplicationState(&component_state);
			buf.WriteStringHash(component->GetType());
			buf.WriteNetID(component->GetID());
			component->WriteInitialDeltaUpdate(buf, 0);
		}

		send_to_peer(peer, "replicate:create_node", buf);

		node_state.markedDirty_ = false;
		scene_state.dirtyNodes_.Erase(node->GetID());
	}

	void sync_existing_node(PeerId peer,
			Node *node, magic::NodeReplicationState &node_state,
			magic::SceneReplicationState &scene_state)
	{
		log_d(MODULE, "sync_existing_node(): %zu", node->GetID());

		// Handle changed attributes
		if(node_state.dirtyAttributes_.Count() || node_state.dirtyVars_.Size()){
			log_d(MODULE, "sync_existing_node(): %zu: Changed attributes "
					"or variables", node->GetID());
			const magic::Vector<magic::AttributeInfo> &attributes =
					*node->GetNetworkAttributes();
			uint num = attributes.Size();
			bool has_latest_data = false;

			// ?
			for(uint i = 0; i < num; i++){
				if(node_state.dirtyAttributes_.IsSet(i) &&
						(attributes.At(i).mode_ & magic::AM_LATESTDATA)){
					has_latest_data = true;
					node_state.dirtyAttributes_.Clear(i);
				}
			}

			// ?
			if(has_latest_data){
				magic::VectorBuffer buf;

				buf.WriteNetID(node->GetID());
				node->WriteLatestDataUpdate(buf, 0);

				send_to_peer(peer, "replicate:latest_node_data", buf);
			}

			// ?
			if(node_state.dirtyAttributes_.Count() || node_state.dirtyVars_.Size()){
				magic::VectorBuffer buf;

				buf.WriteNetID(node->GetID());
				node->WriteDeltaUpdate(buf, node_state.dirtyAttributes_, 0);

				// Variables
				buf.WriteVLE(node_state.dirtyVars_.Size());
				const magic::VariantMap &vars = node->GetVars();
				const magic::HashSet<magic::StringHash> &dirty_vars =
						node_state.dirtyVars_;
				for(auto it = dirty_vars.Begin(); it != dirty_vars.End(); ++it){
					auto var_it = vars.Find(*it);
					if(var_it != vars.End()){
						buf.WriteStringHash(var_it->first_);
						buf.WriteVariant(var_it->second_);
					} else {
						// Variable has been removed; send dummy data
						buf.WriteStringHash(magic::StringHash());
						buf.WriteVariant(magic::Variant::EMPTY);
					}
				}

				send_to_peer(peer, "replicate:node_delta_update", buf);
			}

			node_state.dirtyAttributes_.ClearAll();
			node_state.dirtyVars_.Clear();
		}

		// Handle changed or removed components
		magic::HashMap<unsigned, magic::ComponentReplicationState>
				&component_states = node_state.componentStates_;
		for(auto it = component_states.Begin(); it != component_states.End();){
			auto current_it = it++;
			uint component_id = current_it->first_;
			auto &component_state = current_it->second_;
			magic::Component *component = component_state.component_;
			if(!component){
				// Component was removed
				magic::VectorBuffer buf;
				buf.WriteNetID(component_id);
				send_to_peer(peer, "replicate:remove_component", buf);
				component_states.Erase(current_it);
				continue;
			}
			// Existing component
			// Handle changed attributes
			if(component_state.dirtyAttributes_.Count()){
				log_d(MODULE, "sync_existing_node(): %zu: Changed attributes"
						" in component %zu", node->GetID(), component_id);
				const magic::Vector<magic::AttributeInfo> &attributes =
						*component->GetNetworkAttributes();
				uint num = attributes.Size();
				bool has_latest_data = false;

				// ?
				for(uint i = 0; i < num; i++){
					if(component_state.dirtyAttributes_.IsSet(i) &&
							(attributes.At(i).mode_ & magic::AM_LATESTDATA)){
						has_latest_data = true;
						component_state.dirtyAttributes_.Clear(i);
					}
				}

				// ?
				if(has_latest_data){
					magic::VectorBuffer buf;

					buf.WriteNetID(component->GetID());
					component->WriteLatestDataUpdate(buf, 0);

					send_to_peer(peer, "replicate:latest_component_data", buf);
				}

				// ?
				if(component_state.dirtyAttributes_.Count()){
					magic::VectorBuffer buf;

					buf.WriteNetID(component->GetID());
					component->WriteDeltaUpdate(buf,
							component_state.dirtyAttributes_, 0);

					send_to_peer(peer, "replicate:component_delta_update", buf);

					component_state.dirtyAttributes_.ClearAll();
				}
			}
		}

		// Handle new components
		if(component_states.Size() != node->GetNumNetworkComponents()){
			const magic::Vector<magic::SharedPtr<Component>>
					&components = node->GetComponents();
			for(uint i = 0; i<components.Size(); i++){
				Component *component = components[i];
				if(component->GetID() >= magic::FIRST_LOCAL_ID)
					continue;
				auto it = component_states.Find(component->GetID());
				if(it != component_states.End())
					continue;
				magic::ComponentReplicationState &component_state =
						component_states[component->GetID()];
				component_state.connection_ = (magic::Connection*)&scene_state;
				component_state.nodeState_ = &node_state;
				component_state.component_ = component;
				component->AddReplicationState(&component_state);

				magic::VectorBuffer buf;
				buf.WriteNetID(node->GetID());
				buf.WriteStringHash(component->GetType());
				buf.WriteNetID(component->GetID());
				component->WriteInitialDeltaUpdate(buf, 0);

				send_to_peer(peer, "replicate:create_component", buf);
			}
		}

		node_state.markedDirty_ = false;
		scene_state.dirtyNodes_.Erase(node->GetID());
	}

	// One packet to one peer. A sync pass sends several of these per node it
	// walks, and a network::access() is a hop into another module's thread,
	// so during a pass they are collected and sent in one hop at the end --
	// see sync_changes(). Outside a pass there is nothing to collect them
	// for, and the packet goes at once.
	//
	// The order is kept, which is what matters: a create before the update
	// that follows it.
	struct PendingSend
	{
		PeerId peer;
		ss_ name;
		ss_ data;
	};
	sv_<PendingSend> m_pending_sends;
	bool m_collecting_sends = false;

	void send_to_peer(PeerId peer, const ss_ &name, const magic::VectorBuffer &buf)
	{
		log_d(MODULE, "%s: Update size: %zu", cs(name), buf.GetBuffer().Size());
		ss_ data = buf_to_string(buf);
		if(m_collecting_sends){
			m_pending_sends.push_back(PendingSend{peer, name, data});
			return;
		}
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, name, data);
		});
	}

	void flush_pending_sends()
	{
		if(m_pending_sends.empty())
			return;
		network::access(m_server, [&](network::Interface *inetwork){
			for(const PendingSend &s : m_pending_sends)
				inetwork->send(s.peer, s.name, s.data);
		});
		m_pending_sends.clear();
	}

	// Interface

	void assign_scene_to_peer(
			main_context::SceneReference scene_ref, PeerId peer)
	{
		log_v(MODULE, "assign_scene_to_peer(): scene_ref=%p, peer=%i",
				scene_ref, peer);
		if(scene_ref == nullptr){
			auto it = m_peers.find(peer);
			if(it == m_peers.end())
				return; // Peer wasn't in any scene
			PeerState &ps = it->second;
			m_server->emit_event("replicate:peer_left_scene",
					new PeerLeftScene(peer, ps.scene_ref));
			m_peers.erase(peer);

			log_w(MODULE, "assign_scene_to_peer(): Deassign not properly"
					" implemented");
			// TODO: Tell client to remove replicated nodes and components
		} else {
			m_server->emit_event("replicate:peer_joined_scene",
					new PeerJoinedScene(peer, scene_ref));
			PeerState &ps = m_peers[peer];
			ps.peer_id = peer;
			ps.scene_ref = scene_ref;
		}
	}

	sv_<PeerId> find_peers_on_scene(
			main_context::SceneReference scene_ref)
	{
		sv_<PeerId> result;
		for(auto &pair : m_peers){
			PeerState &ps = pair.second;
			if(ps.scene_ref == nullptr || ps.scene_ref != scene_ref)
				continue;
			result.push_back(ps.peer_id);
		}
		return result;
	}

	sv_<PeerId> find_peers_that_know_node(
			main_context::SceneReference scene_ref, uint node_id)
	{
		sv_<PeerId> result;
		for(auto &pair : m_peers){
			PeerState &ps = pair.second;
			if(ps.scene_ref == nullptr || ps.scene_ref != scene_ref)
				continue;
			auto &node_states = ps.scene_state.nodeStates_;
			auto it = node_states.Find(node_id);
			if(it != node_states.End()){
				result.push_back(ps.peer_id);
			}
		}
		return result;
	}

	void set_node_filter(main_context::SceneReference scene_ref,
			std::function<bool(PeerId, uint)> filter)
	{
		if(filter)
			m_node_filters[scene_ref] = filter;
		else
			m_node_filters.erase(scene_ref);
	}

	void set_node_priority(main_context::SceneReference scene_ref,
			std::function<float(PeerId, uint)> priority)
	{
		if(priority)
			m_node_priorities[scene_ref] = priority;
		else
			m_node_priorities.erase(scene_ref);
	}

	// Every node of the scene goes back into the peer's dirty set, so that
	// the next sync asks the filter about each of them: the ones it has and
	// should not, and the ones it should have and does not.
	void refresh_peer_nodes(
			main_context::SceneReference scene_ref, PeerId peer)
	{
		auto peer_it = m_peers.find(peer);
		if(peer_it == m_peers.end() || peer_it->second.scene_ref != scene_ref)
			return;
		PeerState &ps = peer_it->second;
		main_context::access(m_server, [&](main_context::Interface *imc){
			magic::Scene *scene = imc->find_scene(scene_ref);
			if(!scene){
				log_w(MODULE, "refresh_peer_nodes(): Scene %p not found",
						scene_ref);
				return;
			}
			magic::PODVector<Node*> children;
			scene->GetChildren(children, true);
			for(uint i = 0; i < children.Size(); i++){
				uint id = children[i]->GetID();
				if(id < magic::FIRST_LOCAL_ID)
					ps.scene_state.dirtyNodes_.Insert(id);
			}
		});
	}

	void sync_node_immediate(
			main_context::SceneReference scene_ref, uint node_id)
	{
		main_context::access(m_server, [&](main_context::Interface *imc){
			for(auto &pair: m_peers){
				PeerState &ps = pair.second;
				if(ps.scene_ref == nullptr || ps.scene_ref != scene_ref)
					continue;
				magic::Scene *scene = imc->find_scene(ps.scene_ref);
				if(!scene){
					log_w(MODULE, "sync_node_immdiate(): Scene %p not found",
							ps.scene_ref);
					continue;
				}
				Node *n = scene->GetNode(node_id);
				if(!n){
					log_w(MODULE, "sync_node_immediate(): Node %i not found",
							node_id);
					continue;
				}
				// Compare attributes and set replication states dirty as needed;
				// this accesses every replication state for every child node.
				// NOTE: This can be called multiple times; only the first call
				//       will do anything as it clears the marked-for-update lists
				n->PrepareNetworkUpdate();

				// [LOAD_OWN_CHUNK] A node new to the peer goes with the rest
				// of its dirty set, in the scene's priority order and behind
				// its backpressure: a world being loaded round a joining
				// player committed 20 MB of chunks this way, in commit
				// order, and the one the player stood in came last
				if(ps.scene_state.nodeStates_.Find(node_id) ==
						ps.scene_state.nodeStates_.End()){
					ps.scene_state.dirtyNodes_.Insert(node_id);
					continue;
				}

				magic::HashSet<uint> nodes_to_process;
				nodes_to_process.Insert(node_id);

				while(!nodes_to_process.Empty()){
					uint node_id = nodes_to_process.Front();
					sync_node(ps.peer_id, node_id, nodes_to_process, scene,
							ps.scene_state);
				}
			}
		});
	}

	void* get_interface()
	{
		return dynamic_cast<Interface*>(this);
	}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_replicate(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
