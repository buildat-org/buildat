// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// [SKELDAT_MODULAR] **The stacks on the ground** ([SKELDAT_DEATH_DROPS]):
// each falls until it rests on a voxel (through water to the bed) and is
// gone a game day after the drop; "skeldat_drop" in the scene, its item
// in the var "skeldat_item"; saved as "drop/<n>", "x y z age stack". Who
// picks one up is the players' (step()'s offer). A skull a skeleton
// dropped down a deep hole ([SKELDAT_SURFACE_END]) is no one's, and
// resting it is a skull voxel.
// Included by main.cpp inside namespace skeldat, after world_view.h
#pragma once

struct Drops
{
	WorldView &world;
	// The world's save, from its start
	storage::Store *store = nullptr;
	std::vector<Drop> all;

	Drops(WorldView &world): world(world) {}

	void load()
	{
		ss_ v;
		for(const ss_ &key : store->list("drop/")){
			Drop d;
			ss_ item;
			std::istringstream is;
			if(store->get(key, v) && (is.str(v), is>>d.x>>d.y>>d.z>>d.age) &&
					std::getline(is>>std::ws, item) &&
					!(d.st = Stack::parse(item)).empty())
				all.push_back(d);
		}
		if(!all.empty())
			log_i(MODULE, "skeldat: %zu drops on the ground", all.size());
	}
	void save()
	{
		for(const ss_ &key : store->list("drop/"))
			store->remove(key);
		for(size_t i = 0; i < all.size(); i++){
			const Drop &d = all[i];
			std::ostringstream ds;
			ds<<d.x<<" "<<d.y<<" "<<d.z<<" "<<d.age<<" "<<d.st.str();
			store->set("drop/"+itos(i), ds.str());
		}
	}

	void drop(const Stack &st, float x, float y, float z, float vx = 0,
			float vy = 0, float vz = 0, const ss_ &owner = "")
	{
		if(st.empty())
			return;
		Drop d;
		d.st = st;
		d.x = x, d.y = y, d.z = z, d.vx = vx, d.vy = vy, d.vz = vz;
		d.owner = owner;
		all.push_back(d);
		log_i(MODULE, "skeldat: a drop of %s at %.1f,%.1f,%.1f", cs(st.str()),
				x, y, z);
	}

	// A skull down a deep hole, falling from x, y, z
	void seed_skull(float x, float y, float z)
	{
		Drop d;
		d.st = Stack("skeldat:skull");
		d.seed = true;
		d.x = x, d.y = y, d.z = z;
		all.push_back(d);
	}

	// dt of falling and ageing (gone at day_s); offer(d) gives the players
	// a drop that is there to be picked up, which takes from d.st
	void step(float dt, float day_s, const std::function<void(Drop &)> &offer)
	{
		if(all.empty())
			return;
		sv_<Drop> kept;
		sv_<uint32_t> gone;
		sv_<pv::Vector3DInt32> seeds;
		voxelworld::access(world.server, world.scene,
				[&](voxelworld::Instance *w){
			for(Drop &d : all){
				d.age += dt;
				if(d.age > day_s){
					log_i(MODULE, "skeldat: the drop of %s at %.1f,%.1f,%.1f "
							"is gone", cs(d.st.str()), d.x, d.y, d.z);
					gone.push_back(d.node_id);
					continue;
				}
				// Its ground dug away
				if(d.resting && !world.walkable(w, (int)std::floor(d.x + 0.5f),
						(int)std::floor(d.y), (int)std::floor(d.z + 0.5f)))
					d.resting = false, d.vy = 0;
				if(!d.resting){
					d.vy = std::max(d.vy - GRAVITY * dt, -30.0f);
					const float nx = d.x + d.vx * dt, nz = d.z + d.vz * dt;
					if(world.walkable(w, (int)std::floor(nx + 0.5f),
							(int)std::floor(d.y + 0.5f),
							(int)std::floor(nz + 0.5f)))
						d.vx = d.vz = 0;
					else
						d.x = nx, d.z = nz;
					// Under a voxel a step, so the check below meets each:
					// a join's long tick dropped stacks through the ground.
					// simplified: slower than its speed on a long tick
					const float ny = d.y + std::max(d.vy * dt, -0.9f);
					const int vy = (int)std::floor(ny + 0.5f);
					if(d.vy < 0 && world.walkable(w, (int)std::floor(d.x + 0.5f),
							vy, (int)std::floor(d.z + 0.5f))){
						d.y = vy + 0.5f;
						d.resting = true;
						log_i(MODULE, "skeldat: the drop of %s rests at "
								"%.1f,%.1f,%.1f", cs(d.st.str()), d.x, d.y, d.z);
					} else
						d.y = ny;
					// simplified: below the world it is lost at once
					if(d.y < world.y0 * skeldat::bones::SECTION - 8){
						gone.push_back(d.node_id);
						continue;
					}
				}
				if(d.seed){
					if(d.resting){
						// Over what it rests on, if that is free
						const pv::Vector3DInt32 at((int)std::floor(d.x + 0.5f),
								(int)std::floor(d.y + 0.5f),
								(int)std::floor(d.z + 0.5f));
						if(world.wid(w, at.getX(), at.getY(), at.getZ()) ==
								ID_AIR)
							seeds.push_back(at);
						gone.push_back(d.node_id);
						continue;
					}
					kept.push_back(d);
					continue;
				}
				offer(d);
				if(d.st.empty()){
					gone.push_back(d.node_id);
					continue;
				}
				kept.push_back(d);
			}
		});
		const uint32_t skull = seeds.empty() ? ID_IGNORE :
				world.id_of("skeldat:skull");
		for(const pv::Vector3DInt32 &p : seeds){
			world.set_node(p.getX(), p.getY(), p.getZ(), skull, 0,
					skeldat::bones::MAX);
			log_i(MODULE, "skeldat: a dropped skull is a voxel at %d,%d,%d",
					p.getX(), p.getY(), p.getZ());
		}
		main_context::access(world.server, world.scene,
				[&](Urho3D::Scene *scene){
			for(uint32_t id : gone)
				if(Urho3D::Node *n = id ? scene->GetNode(id) : nullptr)
					n->Remove();
			for(Drop &d : kept){
				Urho3D::Node *n = d.node_id ? scene->GetNode(d.node_id) : nullptr;
				if(!n){
					n = scene->CreateChild("skeldat_drop");
					n->SetVar(Urho3D::StringHash("skeldat_item"),
							Urho3D::Variant(Urho3D::String(d.st.name.c_str())));
					d.node_id = n->GetID();
				}
				if(n->GetPosition() != Urho3D::Vector3(d.x, d.y, d.z))
					n->SetPosition(Urho3D::Vector3(d.x, d.y, d.z));
			}
		});
		all.swap(kept);
	}
};
// vim: set noet ts=4 sw=4:
