// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// [SKELDAT_MODULAR] **The mobs, the arrows and the light skeletons**
// (skelenti's mobs, main.cpp there, with the world read in C++): the
// boars and skeletons near the players, their bodies, damage and drops,
// the arrows in flight and stuck, the marker skulls, and the skeletons
// over the whole world in their light form (the population, the light
// steps, the routes, the far view). Saved as "mob/<key>" by the Module.
// It reaches the players through MobsHost, which the Module is.
// Included by main.cpp inside namespace skeldat, after bones_growth.h
#pragma once

struct MobsHost
{
	virtual Player* nearest(float x, float y, float z, float &d,
			size_t *peer_out = nullptr) = 0;
	virtual void hurt(size_t peer, Player &pl, int damage, const char *how,
			bool drops = true) = 0;
	virtual void send_inventory(size_t peer, const Player &pl) = 0;
	virtual void send_position(size_t peer, Player &pl) = 0;
	virtual void sound(const char *moment, float x, float y, float z,
			size_t except = (size_t)-1) = 0;
	// [SKELDAT_SOUNDS_HEARD] The picker's own, not placed; a shooter's own
	// arrow, heard from further
	virtual void sound_own(size_t peer, const char *moment) = 0;
	virtual void sound_near(size_t peer, const char *moment, float x,
			float y, float z) = 0;
protected:
	~MobsHost() {}
};

struct Mobs
{
	WorldView &world;
	std::map<size_t, Player> &players;
	MobsHost &host;
	Drops &drops;
	BonesGrowth &growth;
	Furnaces &furnaces;
	// The world's save, from its start
	storage::Store *store = nullptr;
	// The mobs, by key; the arrows in flight or stuck
	std::map<uint32_t, Mob> all;
	float light_step = LIGHT_STEP;
	// Day 1, night 0, -1 before the world is in; the night's bone blocks
	int phase = -1;
	// [SKELDAT_SKULL_CALL] In the hour before sunset
	bool calling = false;
	size_t night_blocks = 0;
	uint32_t next_mob = 1;
	std::vector<Arrow> arrows;
	// Bodies put back on their light form, for the report
	size_t body_puts = 0;
	float far_t = 0;
	// Each skeldat:far's count logged, for a check (BUILDAT_SKELDAT_FAR=1)
	bool far_report = getenv("BUILDAT_SKELDAT_FAR") != nullptr;
	float ai_t = 0, spawn_t = 0;
	// Marker skulls a footprint, kept through the world's on_set, saved as
	// "markers"
	sv_<int> markers;
	// [SKELDAT_SURFACE_END] The game day a skull was last dropped down a
	// deep hole, by column; saved as "holes"
	std::map<long, int> hole_day;
	// [SKELDAT_BOW] The stuck_arrow voxels, by "x,y,z", kept through
	// the world's on_set and saved as "stuck/<x,y,z>"
	std::set<ss_> stuck;
	size_t sweep = 0;
	float sweep_t = 0, hour_t = 0;
	double light_us = 0;
	// The next goal walk's search's game time (WALK_SEARCH_WAIT), and
	// whose it is: the longest waiting of the last step's
	double walk_search_t = 0;
	uint32_t walk_next = 0;
	bool walk_queued = false;
	size_t light_steps = 0, activated = 0;
	// [SKELDAT_SUN_SHELTER] Steps refused for the sun, for the report
	size_t sun_kept = 0;
	// BUILDAT_SKELDAT_TEST, for the checks: "boar 0 3; skeleton 0 9" -- no
	// spawning of its own, and the mobs named at x, z from the first
	// player placed, once, standing still for half a minute; "bones 1 0 8"
	// sets the bones of the ground voxel at x, z
	ss_ test;
	bool test_done = false;
	// A test item another part knows (the hazards' "pocket"): true if taken
	std::function<bool(const ss_ &, std::istream &, Player &)> test_more;

	Mobs(WorldView &world, std::map<size_t, Player> &players, MobsHost &host,
			Drops &drops, BonesGrowth &growth, Furnaces &furnaces):
		world(world), players(players), host(host), drops(drops),
		growth(growth), furnaces(furnaces)
	{}

	// A place for a kind to spawn near a player, 12 to 24 voxels off: a
	// boar on grass under the open sky, a skeleton on a floor no light
	// reaches -- or on any floor where the danger d is DAYLIGHT_DANGER or
	// more
	// [SKELDAT_BOAR_GRASS] No walkable voxel from y + 2 to the world's top:
	// a shaft's floor in the ground, lit by its sky light 15, is not open
	// simplified: a straight column; under an overhang open beside it is
	// a cave
	size_t covered = 0; // the spots it refused, for the test's count
	bool open_sky(voxelworld::Instance *w, int x, int y, int z)
	{
		const int top = (world.y1 + 1) * skeldat::bones::SECTION - 1;
		for(int yy = y + 2; yy <= top; yy++)
			if(world.walkable(w, x, yy, z))
				return false;
		return true;
	}

	bool spawn_spot(voxelworld::Instance *w, uint8_t kind, const Player &p,
			float d, float out[3])
	{
		const uint32_t grass = world.id_of("skeldat:grass");
		for(int i = 0; i < 8; i++){
			const float r = 12 + world.rnd() * 12, t = world.rnd() * 2 * (float)M_PI;
			const int x = (int)std::floor(p.x + r * std::cos(t) + 0.5f),
					z = (int)std::floor(p.z + r * std::sin(t) + 0.5f),
					y0 = (int)std::floor(p.y + 0.5f);
			for(int y = y0 + 12; y >= y0 - 16; y--){
				const uint32_t below = world.wid(w, x, y - 1, z);
				if(below == ID_IGNORE || !world.walkable(w, x, y - 1, z) ||
						world.walkable(w, x, y, z) || world.walkable(w, x, y + 1, z) ||
						world.is_water(w, x, y, z))
					continue;
				int sky, lamp;
				world.light(w, x, y, z, sky, lamp);
				if(kind == BOAR && below == grass && sky == 15 &&
						!open_sky(w, x, y, z)){
					covered++;
					continue;
				}
				// [SKELDAT_CAVE_SKELETON] A cave skeleton: unlit, and the
				// column over it closed
				if(kind == BOAR ? below == grass && sky == 15 :
						kind == CAVE_SKELETON ? std::max(sky, lamp) <= 3 &&
							!open_sky(w, x, y, z) :
						d >= DAYLIGHT_DANGER || std::max(sky, lamp) <= 3){
					out[0] = (float)x, out[1] = y - 0.5f, out[2] = (float)z;
					return true;
				}
			}
		}
		return false;
	}

	void spawn()
	{
		for(auto &pair : players){
			const Player &p = pair.second;
			if(!p.placed || p.hp <= 0)
				continue;
			float d = 0;
			voxelworld::access(world.server, world.scene, [&](voxelworld::Instance *w){
				d = world.danger(w, p.x, p.y, p.z);
			});
			size_t active = 0;
			for(auto &kv : all)
				active += kv.second.node_id != 0;
			for(uint8_t kind : {BOAR, SKELETON, CAVE_SKELETON}){
				if(active >= MAX_MOBS)
					return;
				if(kind == BOAR && (world.day < 0.25 || world.day > 0.75))
					continue;
				size_t near = 0;
				for(auto &kv : all){
					const Mob &m = kv.second;
					if(m.kind == kind && m.node_id && std::fabs(m.x-p.x) < 32 &&
							std::fabs(m.z-p.z) < 32 && std::fabs(m.y-p.y) < 32)
						near++;
				}
				// A skeleton by the danger: more tries, more of them
				if(near >= (kind == SKELETON ? 1 + (size_t)(5 * d) :
						kind == CAVE_SKELETON ? 2 : MAX_NEAR))
					continue;
				if(kind == SKELETON && world.rnd() > 0.1f + 0.9f * d)
					continue;
				// One try in ten a spawn tick, by day or night
				if(kind == CAVE_SKELETON && world.rnd() > 0.1f)
					continue;
				float s[3];
				bool found = false;
				voxelworld::access(world.server, world.scene, [&](voxelworld::Instance *w){
					found = spawn_spot(w, kind, p, d, s);
				});
				if(!found)
					continue;
				size_t area = 0;
				for(auto &kv : all)
					if(std::fabs(kv.second.x - s[0]) < 32 &&
							std::fabs(kv.second.z - s[2]) < 32)
						area++;
				if(area >= (kind == SKELETON ? 2 + (size_t)(8 * d) :
						kind == CAVE_SKELETON ? 4 : MAX_AREA))
					continue;
				Mob m;
				m.kind = kind;
				m.x = s[0], m.y = s[1], m.z = s[2];
				m.hp = MOB_HP[kind];
				m.yaw = world.rnd() * 2 * (float)M_PI;
				m.grass_t = world.t;
				const uint32_t k = next_mob++;
				all[k] = m;
				active++;
				log_i(MODULE, "skeldat: a %s (%u) spawns at %.1f,%.1f,%.1f, "
						"danger %.2f", MOB_KIND[kind], k, m.x, m.y, m.z, d);
			}
		}
	}

	void stage_test()
	{
		if(test_done)
			return;
		Player *p = nullptr;
		size_t peer = 0;
		// The first placed (the lowest peer: the first to join, when two
		// are placed by the time the world is in)
		for(auto &pair : players)
			if(pair.second.placed){
				p = &pair.second, peer = pair.first;
				break;
			}
		if(!p)
			return;
		test_done = true;
		std::istringstream is(test);
		ss_ item;
		while(std::getline(is, item, ';')){
			std::istringstream it(item);
			ss_ kind;
			it>>kind;
			if(test_more && test_more(kind, it, *p))
				continue;
			if(kind == "place"){
				// "place x z": the player moved onto that column's top
				int x = 0, z = 0;
				it>>x>>z;
				int y = (world.y1 + 1) * skeldat::bones::SECTION - 1;
				while(y > world.y0 * skeldat::bones::SECTION &&
						world.id_at(x, y - 1, z) == ID_AIR)
					y--;
				p->x = (float)x, p->y = (float)y, p->z = (float)z;
				host.send_position(peer, *p);
				log_i(MODULE, "skeldat: test: %s placed at %d,%d,%d",
						cs(p->name), x, y, z);
				continue;
			}
			if(kind == "boar_spots" || kind == "cave_spots"){
				// [SKELDAT_BOAR_GRASS] "boar_spots n": n boar spawn searches
				// round the player, counted; "cave_spots n" a cave
				// skeleton's ([SKELDAT_CAVE_SKELETON])
				const uint8_t k = kind == "boar_spots" ? BOAR : CAVE_SKELETON;
				int n = 0, found = 0;
				it>>n;
				covered = 0;
				voxelworld::access(world.server, world.scene, [&](voxelworld::Instance *w){
					float out[3];
					for(int i = 0; i < n; i++)
						found += spawn_spot(w, k, *p, 0, out);
				});
				log_i(MODULE, "skeldat: test: %d %s spawn searches, %d found, "
						"%zu covered spots refused", n, MOB_KIND[k], found, covered);
				continue;
			}
			// The world's own mobs kept (main.cpp's populate())
			if(kind == "populate")
				continue;
			if(kind == "give"){
				// "give item n k": k stacks of n into the player's main
				int n = 0, k = 1;
				ss_ name;
				it>>name>>n>>k;
				for(int i = 0; i < k && world.game.item(name); i++)
					world.game.add(p->main, Stack(name, n));
				host.send_inventory(peer, *p);
				log_i(MODULE, "skeldat: test: %d of %s given", k, cs(name));
				continue;
			}
			if(kind == "craft"){
				// "craft i item n": the player's craft slot i (1-9) holds n
				int i = 0, n = 0;
				ss_ name;
				it>>i>>name>>n;
				if(i >= 1 && i <= 9 && world.game.item(name)){
					p->craft[i - 1] = Stack(name, n);
					host.send_inventory(peer, *p);
					log_i(MODULE, "skeldat: test: %s in craft %d", cs(name), i);
				}
				continue;
			}
			float dx = 0, dz = 0;
			it>>dx>>dz;
			if(kind == "marker"){
				// "marker dx dz [node [dy]]": a marker skull, or the node,
				// on the ground there, or dy over that (-1 the ground's top);
				// the ground looked for from 2 over the player's feet down
				// to 16 under them, or from the column's top over that if
				// it is higher (markers stacked by dy 0)
				ss_ name;
				int dy = -1000;
				it>>name>>dy;
				const uint32_t id = name.empty() ? world.marker : world.id_of(name);
				const int x = (int)std::floor(p->x + dx + 0.5f),
						z = (int)std::floor(p->z + dz + 0.5f);
				int y = (int)std::floor(p->y + 0.5f) + 2;
				for(int up = 0; up < 32 && world.id_at(x, y, z) != ID_AIR; up++)
					y++;
				while(y > (int)std::floor(p->y + 0.5f) - 16 &&
						world.id_at(x, y - 1, z) == ID_AIR)
					y--;
				if(dy > -1000)
					y += dy;
				world.set_node(x, y, z, id);
				log_i(MODULE, "skeldat: test: %s at %s", name.empty() ?
						"a marker skull" : cs(name), cs(pos_key(x, y, z)));
				continue;
			}
			if(kind == "drop"){
				// [SKELDAT_LOOT_GROUND] "drop dx dz item n": a stack dropped
				// there, no one's
				int n = 1;
				ss_ name;
				it>>name>>n;
				drops.drop(Stack(name, n), p->x + dx, p->y + 0.5f, p->z + dz);
				continue;
			}
			if(kind == "level"){
				// [SKELDAT_BRIDGES_SEEN] "level dx dz w d node dy": the node
				// at the player's feet + dy over w x d columns from there,
				// and air 6 over it, so a river's water is at one height;
				// stone under it down to the ground (where the ground is
				// lower, nothing walks under the water)
				ss_ name;
				int w = 0, d = 0, dy = 0;
				it>>w>>d>>name>>dy;
				const uint32_t id = world.id_of(name);
				const int x0 = (int)std::floor(p->x + dx + 0.5f),
						z0 = (int)std::floor(p->z + dz + 0.5f),
						y = (int)std::floor(p->y + 0.5f) + dy;
				for(int z = z0; z < z0 + d; z++)
				for(int x = x0; x < x0 + w; x++){
					world.set_node(x, y, z, id);
					for(int k = 1; k <= 6; k++)
						world.set_node(x, y + k, z, ID_AIR);
					for(int k = 1; k <= 32 && world.id_at(x, y - k, z) == ID_AIR; k++)
						world.set_node(x, y - k, z, world.id_of("skeldat:stone"));
				}
				log_i(MODULE, "skeldat: test: %s at y %d over %d,%d %dx%d",
						cs(name), y, x0, z0, w, d);
				continue;
			}
			if(kind == "course"){
				// [SKELDAT_SKATEBOARD] "course dx dz": a board's course of
				// stone from there along +x, 5 wide, its heights over the
				// player's ground: a platform of 12, a slope down to 0, a
				// ramp of 2 at 1:2, a flat, a wall of 3 at 64 with a hole
				// one high at its middle ([SKELDAT_BOARD_PRONE]) and one
				// at 70 without; and off
				// x 64..69 a slope down 8 along +z and a flat 70 long. The
				// player put on the platform.
				const int X = (int)std::floor(p->x + dx + 0.5f),
						Z = (int)std::floor(p->z + dz + 0.5f),
						B = (int)std::floor(p->y + 0.5f);
				const uint32_t stone = world.id_of("skeldat:stone");
				auto column = [&](int i, int j, int h){
					const int lo = B + std::min(h, 0) - 3;
					for(int y = lo; y <= std::max(h, 0) + B + 6; y++)
						world.set_node(X + i, y, Z + j, y < B + h ? stone : ID_AIR);
				};
				for(int i = -3; i <= 75; i++)
				for(int j = -2; j <= 2; j++){
					const int h = i < 4 ? 12 : i < 16 ? 15 - i :
							i >= 36 && i < 40 ? (i - 34) / 2 :
							(i >= 70 && i <= 72) || i == 64 || i == 65 ? 3 : 0;
					column(i, j, h);
					if((i == 64 || i == 65) && j == 0)
						world.set_node(X + i, B, Z, ID_AIR);
				}
				for(int i = 64; i <= 69; i++)
				for(int j = 3; j <= 78; j++)
					column(i, j, std::max(-8, 2 - j));
				p->x = (float)X, p->y = (float)(B + 12), p->z = (float)Z;
				host.send_position(peer, *p);
				log_i(MODULE, "skeldat: test: a course at %d,%d,%d", X, B, Z);
				continue;
			}
			if(kind == "lantern"){
				// "lantern dx dz coal": as BUILDAT_SKELDAT_LANTERNS, after
				// what the knobs before it built
				int coal = 1;
				it>>coal;
				furnaces.test_lanterns((itos((int)std::floor(p->x + dx +
						0.5f))+" "+itos((int)std::floor(p->z + dz + 0.5f))+" "+
						itos(coal)).c_str(), world.day_s);
				continue;
			}
			if(kind == "bones"){
				// "bones dx dz value": the ground's voxel there
				int value = 0;
				it>>value;
				const int x = (int)std::floor(p->x + dx + 0.5f),
						y = (int)std::floor(p->y + 0.5f) - 1,
						z = (int)std::floor(p->z + dz + 0.5f);
				voxelworld::access(world.server, world.scene, [&](voxelworld::Instance *w){
					const pv::Vector3DInt32 v(x, y, z);
					interface::VoxelSample sample = w->get_sample(v, true);
					world.bones.set(sample, (uint32_t)value);
					w->set_sample(v, sample);
					// Its column's top_b too, which the boats read
					world.rescan_column(w, x, z);
				});
				log_i(MODULE, "skeldat: test: bones %d at %d,%d,%d", value,
						x, y, z);
				continue;
			}
			Mob m;
			m.kind = kind == "skeleton" ? SKELETON :
					kind == "cave_skeleton" ? CAVE_SKELETON : BOAR;
			m.x = p->x + dx, m.y = p->y, m.z = p->z + dz;
			voxelworld::access(world.server, world.scene, [&](voxelworld::Instance *w){
				Ground g = world.ground(w, m.x, m.y + 2, m.z, MOB_HEIGHT[m.kind]);
				if(g.found)
					m.y = g.y;
			});
			// Not near the player's height: on its column's top
			const long c = world.column((int)std::floor(m.x + 0.5f),
					(int)std::floor(m.z + 0.5f));
			if(m.y == p->y && c >= 0 && world.top_y[c] != NO_GROUND)
				m.y = world.top_y[c] + 0.5f;
			m.hp = MOB_HP[m.kind];
			m.yaw = (float)M_PI;
			m.mode_t = 30;
			m.grass_t = world.t;
			// "... marked": its marker skull placed today, so it places
			// none beside itself, which would keep the sun off it.
			// "... seed dx dz n": n night's blocks, the first at that
			// column off the player
			ss_ flag;
			while(it>>flag){
				if(flag == "marked")
					m.marker_day = world.t / world.day_s;
				if(flag == "hp")
					it>>m.hp;
				if(flag == "lure")
					m.goal_fp = (int)world.footprint((int)std::floor(m.x + 0.5f),
							(int)std::floor(m.z + 0.5f));
				// "... goal dx dz": the footprint there its goal, to walk to
				if(flag == "goal"){
					float gx = 0, gz = 0;
					it>>gx>>gz;
					m.goal_fp = (int)world.footprint((int)std::floor(p->x + gx +
							0.5f), (int)std::floor(p->z + gz + 0.5f));
				}
				// [SKELDAT_BOAT_FAULTS] "... boat days hx hz": on a boat that
				// boarded days ago at the player + hx, hz
				if(flag == "boat"){
					double days = 0;
					float hx = 0, hz = 0;
					it>>days>>hx>>hz;
					m.boat = true;
					m.boarded_t = world.t - days * world.day_s;
					m.boat_x = p->x + hx, m.boat_z = p->z + hz;
					if(c >= 0)
						m.y = world.top_any[c] + 0.5f;
				}
				if(flag == "seed"){
					float sx = 0, sz = 0;
					it>>sx>>sz>>m.quota;
					m.seed_x = (int)std::floor(p->x + sx + 0.5f);
					m.seed_z = (int)std::floor(p->z + sz + 0.5f);
					m.seeding = true;
				}
			}
			const uint32_t k = next_mob++;
			all[k] = m;
			log_i(MODULE, "skeldat: test: a %s (%u) at %.1f,%.1f,%.1f",
					MOB_KIND[m.kind], k, m.x, m.y, m.z);
		}
	}

	// Woken, it has seen nothing yet
	void activate(Mob &m)
	{
		if(m.mode == FIGHT)
			m.mode = WANDER, m.mode_t = 0;
		m.draw_t = -1, m.draw_sent = 0, m.boat_sent = -1;
		m.bx = m.x, m.by = m.y, m.bz = m.z, m.bvy = 0;
		m.dry_t = world.t, m.swim_t = 0, m.swim_to = false;
		activated++;
		main_context::access(world.server, world.scene, [&](Urho3D::Scene *scene){
			Urho3D::Node *n = scene->CreateChild(
					Urho3D::String("skeldat_")+MOB_KIND[m.kind]);
			n->SetPosition(Urho3D::Vector3(m.x, m.y, m.z));
			n->SetRotation(Urho3D::Quaternion(m.yaw * M_RADTODEG,
					Urho3D::Vector3::UP));
			n->SetVar(Urho3D::StringHash("skeldat_hurt"), Urho3D::Variant(m.hurt));
			m.node_id = n->GetID();
		});
	}

	void remove_node(uint32_t &id)
	{
		main_context::access(world.server, world.scene, [&](Urho3D::Scene *scene){
			if(Urho3D::Node *n = scene->GetNode(id))
				n->Remove();
		});
		id = 0;
	}

	// [SKELDAT_BOAR_SWIM] Water this deep or deeper a boar keeps out of; a
	// boar floats with its feet BOAR_FLOAT under the top water voxel's
	// surface, swims at half its walk, heads for dry ground after
	// BOAR_SWIM_DAYS in the water and keeps out of it BOAR_STAY_DAYS after;
	// the columns it looks for within BOAR_SHORE_SEARCH
	static constexpr int DEEP_WATER = 3, BOAR_SHORE_SEARCH = 16;
	static constexpr float BOAR_FLOAT = 0.75f;
	static constexpr double BOAR_SWIM_DAYS = 0.25, BOAR_STAY_DAYS = 0.125;

	// The water in column (x, z) from y + 2 down: how many voxels deep from
	// its top (*top) to the bed, 0 when the first voxel that is not air is
	// not water. Lava is no water
	int water_depth(voxelworld::Instance *w, int x, int y, int z,
			int *top = nullptr)
	{
		const uint32_t lava = world.id_of("skeldat:lava");
		int t = y + 2;
		while(t > y - 40 && world.wid(w, x, t, z) == ID_AIR)
			t--;
		if(top)
			*top = t;
		int n = 0;
		while(n < 40 && world.is_water(w, x, t - n, z) &&
				world.wid(w, x, t - n, z) != lava)
			n++;
		return n;
	}

	// The nearest column round a boar, ring by ring: dry ground it can
	// stand on, or water less than DEEP_WATER deep. Its middle in *x, *z
	bool boar_column(voxelworld::Instance *w, const Mob &m, bool dry,
			float *x, float *z)
	{
		const int x0 = (int)std::floor(m.x + 0.5f), y0 = (int)std::floor(m.y + 0.5f),
				z0 = (int)std::floor(m.z + 0.5f);
		for(int r = 1; r <= BOAR_SHORE_SEARCH; r++)
		for(int dz = -r; dz <= r; dz++)
		for(int dx = -r; dx <= r; dx += (std::abs(dz) == r ? 1 : 2 * r)){
			const int d = water_depth(w, x0 + dx, y0, z0 + dz);
			if(dry ? d == 0 && world.ground(w, (float)(x0 + dx), m.y + 1,
					(float)(z0 + dz), MOB_HEIGHT[BOAR]).found : d < DEEP_WATER){
				*x = (float)(x0 + dx), *z = (float)(z0 + dz);
				return true;
			}
		}
		return false;
	}

	// A boar gone with no drops and no hurt, its death sound where it was
	// unless quiet; why it went logged
	void vanish(uint32_t key, const char *why, bool quiet = false)
	{
		Mob &m = all[key];
		log_i(MODULE, "skeldat: the boar (%u) %s at %.1f,%.1f,%.1f", key, why,
				m.x, m.y, m.z);
		if(!quiet)
			host.sound("boar_death", m.x, m.y, m.z);
		if(m.node_id)
			remove_node(m.node_id);
		if(store)
			store->remove("mob/"+itos(key));
		all.erase(key);
	}

	// A boar stepped in water DEEP_WATER deep or more: gone, not kept, as
	// it goes out of the step and when the world closes ([SKELDAT_BOAR_SWIM])
	bool in_deep_water(const Mob &m)
	{
		bool deep = false;
		voxelworld::access(world.server, world.scene, [&](voxelworld::Instance *w){
			deep = water_depth(w, (int)std::floor(m.x + 0.5f),
					(int)std::floor(m.y + 0.5f), (int)std::floor(m.z + 0.5f)) >=
					DEEP_WATER;
		});
		return deep;
	}

	void leave_deep_water()
	{
		sv_<uint32_t> gone;
		for(auto &kv : all)
			if(kv.second.kind == BOAR && kv.second.node_id &&
					in_deep_water(kv.second))
				gone.push_back(kv.first);
		for(uint32_t key : gone)
			vanish(key, "left in deep water", true);
	}

	// [SKELDAT_CAVE_SKELETON] What a skeleton fights (target_of()): a
	// player (peer) or a mob (key), where it is and its name for the log
	struct Target {
		float x = 0, y = 0, z = 0, d = 1e9f;
		size_t peer = 0;
		uint32_t mob = 0;
		bool is_mob = false;
		ss_ name;
	};

	// [SKELDAT_SKELETON_DRAW] The bow drawn this long before the shot;
	// the next draw 0.7 to 2.2 s after it, 1.5 to 3 between the shots
	// with the draw
	static constexpr float DRAW_S = 0.8f;
	void let_go(uint32_t key, Mob &m, const char *why)
	{
		if(m.draw_t < 0)
			return;
		m.draw_t = -1;
		m.shoot_t = 0.7f + world.rnd() * 1.5f;
		log_i(MODULE, "skeldat: a skeleton (%u) lets its draw go: %s", key, why);
	}

	// [SKELDAT_CLEAR_SHOT] Whether the arc shoot() flies from a body at
	// (x, y, z) to p, its spread left out, meets no solid voxel (leaves and
	// bone blocks solid, water not): sampled every 0.25 of its flat
	// distance
	bool clear_shot(voxelworld::Instance *w, float x, float y, float z,
			const Target &p)
	{
		const float dx = p.x - x, dz = p.z - z;
		const float h = std::sqrt(dx*dx + dz*dz);
		if(h < 0.5f)
			return true;
		const float ax = x + dx / h * 0.6f, ay = y + 1.5f, az = z + dz / h * 0.6f;
		const float t = h / ARROW_SPEED;
		const float vy = (p.y + 1.2f - ay) / t + 0.5f * ARROW_GRAVITY * t;
		for(float s = 0; s < h - 0.6f; s += 0.25f){
			const float ts = s / ARROW_SPEED;
			const int vx = (int)std::floor(ax + dx / h * s + 0.5f),
					vyy = (int)std::floor(ay + vy * ts -
					0.5f * ARROW_GRAVITY * ts * ts + 0.5f),
					vz = (int)std::floor(az + dz / h * s + 0.5f);
			if(world.walkable(w, vx, vyy, vz))
				return false;
		}
		return true;
	}

	// [SKELDAT_CLEAR_SHOT] A standing spot near m with a clear shot at p:
	// 8 headings at 2, then at 4, on the column's ground round its height,
	// 3 to 12 from p; its feet voxel in at
	// simplified: within 4 only; a player behind a long wall is not
	// reached (a wider ring, or a search toward p's sight, the upgrade)
	bool shot_spot(voxelworld::Instance *w, const Mob &m, const Target &p,
			int at[3])
	{
		for(int r : {2, 4})
			for(int i = 0; i < 8; i++){
				const float a = i * (float)M_PI / 4;
				const int x = (int)std::floor(m.x + std::sin(a) * r + 0.5f),
						z = (int)std::floor(m.z + std::cos(a) * r + 0.5f);
				const float d = std::hypot(p.x - x, p.z - z);
				if(d < 3 || d > 12)
					continue;
				const Ground g = world.ground(w, (float)x, m.y, (float)z,
						MOB_HEIGHT[m.kind]);
				if(!g.found || g.water || !clear_shot(w, (float)x, g.y, (float)z, p))
					continue;
				at[0] = x, at[1] = (int)std::floor(g.y + 1.0f), at[2] = z;
				return true;
			}
		return false;
	}
	void log_shot_try(uint32_t key, const Mob &m, const Target &p,
			const int *at, const char *none)
	{
		if(at)
			log_i(MODULE, "skeldat: a %s (%u) has no clear shot at %s, to "
					"(%d %d %d)", MOB_KIND[m.kind], key, cs(p.name), at[0],
					at[1], at[2]);
		else
			log_i(MODULE, "skeldat: a %s (%u) has no clear shot at %s, %s",
					MOB_KIND[m.kind], key, cs(p.name), none);
	}

	void shoot(const Mob &m, const Target &p)
	{
		const float dx = p.x - m.x, dz = p.z - m.z;
		const float h = std::sqrt(dx*dx + dz*dz);
		if(h < 0.5f)
			return;
		Arrow a;
		a.x = m.x + dx / h * 0.6f, a.y = m.y + 1.5f, a.z = m.z + dz / h * 0.6f;
		const float t = h / ARROW_SPEED;
		a.vx = dx / h * ARROW_SPEED + (world.rnd() - 0.5f) * 0.8f;
		a.vz = dz / h * ARROW_SPEED + (world.rnd() - 0.5f) * 0.8f;
		a.vy = (p.y + 1.2f - a.y) / t + 0.5f * ARROW_GRAVITY * t +
				(world.rnd() - 0.5f) * 0.6f;
		main_context::access(world.server, world.scene, [&](Urho3D::Scene *scene){
			Urho3D::Node *n = scene->CreateChild("skeldat_arrow");
			n->SetPosition(Urho3D::Vector3(a.x, a.y, a.z));
			a.node_id = n->GetID();
		});
		a.shooter = m.kind;
		arrows.push_back(a);
		host.sound("bow", m.x, m.y + 1.5f, m.z);
		log_i(MODULE, "skeldat: a %s shoots at %s", MOB_KIND[m.kind], cs(p.name));
	}

	sv_<Stack> loot(const Mob &m)
	{
		sv_<Stack> out;
		if(m.kind == BOAR){
			out.push_back(Stack("skeldat:meat_raw", 1 + world.rand() % 2));
			return out;
		}
		const int bones = 1 + world.rand() % 2, shafts = world.rand() % 3;
		if(bones)
			out.push_back(Stack("skeldat:bone", bones));
		if(shafts)
			out.push_back(Stack("skeldat:arrow", shafts));
		// The end game's part: only a deep skeleton has one
		if(m.y < -32 && world.rnd() < 0.34f)
			out.push_back(Stack("skeldat:skull"));
		if(m.carry_coal >= 0){
			out.push_back(Stack("skeldat:lantern"));
			if(m.carry_coal > 0)
				out.push_back(Stack("skeldat:coal", m.carry_coal));
		}
		return out;
	}

	// hp off a mob, by a player's hit or by the sun (by NOBODY); it dies at
	// 0, and what it drops is left on the ground at it, for anyone to pick
	// up ([SKELDAT_LOOT_GROUND])
	static const size_t NOBODY = (size_t)-1;
	// ground_drops: with no killer, its drops left on the ground too
	void damage(uint32_t key, int hp, size_t by, float bx, float bz,
			bool ground_drops = false)
	{
		Mob &m = all[key];
		m.hp -= hp;
		m.hurt++;
		let_go(key, m, "hurt");
		if(m.kind == BOAR){
			m.mode = FLEE;
			m.mode_t = 5;
			m.from_x = bx, m.from_z = bz;
		}
		if(m.hp > 0){
			host.sound(m.kind == BOAR ? "boar_hurt" : "skeleton_hurt", m.x, m.y, m.z);
			return;
		}
		ss_ list;
		auto killer = players.find(by);
		const sv_<Stack> dropped = loot(m);
		for(const Stack &s : dropped)
			list += (list.empty() ? "" : ", ") + s.str();
		const bool ground = killer != players.end() || ground_drops;
		if(ground)
			for(const Stack &s : dropped)
				drops.drop(s, m.x + world.rnd() - 0.5f, m.y + 0.5f, m.z + world.rnd() - 0.5f);
		if(killer == players.end())
			leave_lantern(m);
		log_i(MODULE, "skeldat: the %s (%u) dies at %.1f,%.1f,%.1f, drops %s[%s]",
				MOB_KIND[m.kind], key, m.x, m.y, m.z, ground ? "on the ground " : "",
				cs(list));
		host.sound(m.kind == BOAR ? "boar_death" : "skeleton_death", m.x, m.y, m.z);
		if(m.node_id)
			remove_node(m.node_id);
		if(store)
			store->remove("mob/"+itos(key));
		all.erase(key);
	}

	// The nearest free ground to a mob within three columns, not its own:
	// an air voxel on a walkable one, round the feet's height
	bool marker_spot(voxelworld::Instance *w, const Mob &m, int out[3])
	{
		const int mx = (int)std::floor(m.x + 0.5f),
				my = (int)std::floor(m.y + 0.5f),
				mz = (int)std::floor(m.z + 0.5f);
		for(int r = 1; r <= 3; r++)
		for(int dz = -r; dz <= r; dz++)
		for(int dx = -r; dx <= r; dx++){
			if(std::max(std::abs(dx), std::abs(dz)) != r)
				continue;
			const int x = mx + dx, z = mz + dz;
			for(int y = my + 1; y >= my - 2; y--){
				if(world.wid(w, x, y, z) == ID_AIR && world.walkable(w, x, y - 1, z) &&
						world.reaches_world(x, y, z)){
					out[0] = x, out[1] = y, out[2] = z;
					return true;
				}
			}
		}
		return false;
	}

	// [SKELDAT_CAVE_SKELETON] What a skeleton fights: the nearest of a
	// living player and an active skeleton of the other kind (a bone
	// skeleton's body, a cave skeleton), from the mob's x, y, z
	Target target_of(const Mob &m)
	{
		Target t;
		float d;
		size_t peer = 0;
		if(const Player *p = host.nearest(m.x, m.y, m.z, d, &peer)){
			t.x = p->x, t.y = p->y, t.z = p->z, t.d = d;
			t.peer = peer, t.name = p->name;
		}
		const uint8_t foe = m.kind == SKELETON ? CAVE_SKELETON : SKELETON;
		for(auto &kv : all){
			const Mob &o = kv.second;
			if(o.kind != foe || !o.node_id || o.hp <= 0)
				continue;
			const float e = std::sqrt((o.bx - m.x) * (o.bx - m.x) +
					(o.by - m.y) * (o.by - m.y) + (o.bz - m.z) * (o.bz - m.z));
			if(e < t.d){
				t.x = o.bx, t.y = o.by, t.z = o.bz, t.d = e;
				t.peer = 0, t.mob = kv.first, t.is_mob = true;
				t.name = ss_("the ")+MOB_KIND[foe]+" ("+itos(kv.first)+")";
			}
		}
		return t;
	}

	// The body after its light form ([SKELDAT_LIGHT_PRIMARY]): toward it
	// at BODY_SPEED, a step up as a jump, falling; put on it when BODY_LAG
	// off. It faces the player it fights, else the way it goes
	void step_body(voxelworld::Instance *w, Mob &m, const Target *p, float dt)
	{
		const int h = MOB_HEIGHT[SKELETON];
		const float dx = m.x - m.bx, dz = m.z - m.bz,
				flat = std::sqrt(dx * dx + dz * dz);
		// Behind on the ground; a fall to the floor under it is no lag
		if(flat > BODY_LAG || std::fabs(m.y - m.by) > 3 * BODY_LAG){
			m.bx = m.x, m.by = m.y, m.bz = m.z, m.bvy = 0;
			body_puts++;
		}
		// Drawing its bow it stands ([SKELDAT_SKELETON_DRAW]), turned to
		// the player below
		else if(flat > 0.05f && m.draw_t < 0){
			const float k = std::min(1.0f, BODY_SPEED * dt / flat);
			const float nx = m.bx + dx * k, nz = m.bz + dz * k;
			const Ground to = world.ground(w, nx, m.by, nz, h);
			// Water is a wall to it ([SKELDAT_SKELETON_WATER])
			if(to.found && !to.water && to.y <= m.by + 1.01f){
				m.bx = nx, m.bz = nz;
				if(to.y > m.by)
					m.by = to.y, m.bvy = 0;
			}
			m.yaw = std::atan2(dx, dz);
		}
		const Ground under = world.ground(w, m.bx, m.by, m.bz, h);
		if(under.found && m.by <= under.y + 0.001f)
			m.bvy = 0, m.by = under.y;
		else {
			m.bvy -= GRAVITY * dt;
			m.by += m.bvy * dt;
			if(under.found)
				m.by = std::max(m.by, under.y);
		}
		// Together and the body on its ground, the light form stands there
		// too: one saved or stepped over a cave's mouth floats otherwise
		if(flat <= 0.05f && under.found && m.bvy == 0)
			m.y = m.by;
		if(p && m.mode == FIGHT)
			m.yaw = std::atan2(p->x - m.bx, p->z - m.bz);
	}

	void step_mobs(float dt)
	{
		// Activate what a player is near, make dormant what none is
		sv_<uint32_t> active, left_deep;
		size_t full = 0;
		for(auto &kv : all)
			full += kv.second.node_id != 0;
		for(auto &kv : all){
			Mob &m = kv.second;
			float d;
			host.nearest(m.x, m.y, m.z, d);
			// simplified: the first in key order past MAX_MOBS wait
			if(!m.node_id && d < ACTIVE_WITHIN && full < MAX_MOBS){
				activate(m);
				full++;
			}
			else if(m.node_id && d > DORMANT_PAST){
				if(m.kind == BOAR && in_deep_water(m))
					left_deep.push_back(kv.first);
				remove_node(m.node_id);
				log_v(MODULE, "skeldat: the %s (%u) goes dormant", MOB_KIND[m.kind],
						kv.first);
			}
			if(m.node_id)
				active.push_back(kv.first);
		}
		for(uint32_t key : left_deep)
			vanish(key, "left in deep water", true);
		if(active.empty())
			return;
		sv_<std::pair<uint32_t, int>> burnt, harmed;
		sv_<uint32_t> drowned, off_grass, wet_night;
		sv_<std::pair<uint32_t, Target>> shots, draws;
		struct Mark { uint32_t key; int p[3]; ss_ seen; };
		sv_<Mark> marks;
		voxelworld::access(world.server, world.scene, [&](voxelworld::Instance *w){
			for(uint32_t key : active){
				Mob &m = all[key];
				const int h = MOB_HEIGHT[m.kind];
				// Where the map is not loaded yet, it waits
				const Ground here = world.ground(w, m.x, m.y, m.z, h);
				if(!here.loaded)
					continue;
				// What it wants: a heading and a speed
				m.mode_t -= dt;
				const Target tg = m.kind != BOAR ? target_of(m) : Target();
				const Target *p = tg.d < 1e9f ? &tg : nullptr;
				const float d = tg.d;
				// The draw, then the shot at the target as it is then
				// ([SKELDAT_SKELETON_DRAW]); a cave skeleton's the same.
				// Both on a clear shot only ([SKELDAT_CLEAR_SHOT]): a
				// blocked one looked at again in 0.5 s, a draw that ends
				// on one let go
				auto fight = [&](){
					m.mode = FIGHT;
					if(m.draw_t >= 0){
						m.draw_t -= dt;
						if(m.draw_t <= 0){
							if(!clear_shot(w, m.x, m.y, m.z, tg)){
								let_go(key, m, "no clear shot");
								m.no_shot = true;
								return;
							}
							shots.push_back({key, tg});
							m.draw_t = -1;
							m.shoot_t = 0.7f + world.rnd() * 1.5f;
						}
					} else {
						m.shoot_t -= dt;
						if(m.shoot_t <= 0 && d < 14){
							if(!clear_shot(w, m.x, m.y, m.z, tg)){
								m.no_shot = true;
								m.shoot_t = 0.5f;
								return;
							}
							m.draw_t = DRAW_S;
							draws.push_back({key, tg});
						}
					}
				};
				// The sun burns a skeleton of either kind unless bones are
				// round it, water kills it
				auto burns = [&](float x, float y, float z){
					if(here.sun >= 12){
						m.burn_t += dt;
						if(m.burn_t >= 1){
							m.burn_t = 0;
							if(world.sun_safe(w, x, y, z) == 0)
								burnt.push_back({key, 2});
						}
					}
					if(m.y < -1000)
						burnt.push_back({key, 1000});
				};
				// Water at the feet or the head; lava not ([SKELDAT_SUN_SHELTER]:
				// it burns, as it does a boar, 4 hp a second)
				const uint32_t lava = world.id_of("skeldat:lava");
				auto in_water = [&](float x, float y, float z){
					const int bx = (int)std::floor(x + 0.5f),
							by = (int)std::floor(y + 0.5f),
							bz = (int)std::floor(z + 0.5f);
					return (world.is_water(w, bx, by, bz) &&
							world.wid(w, bx, by, bz) != lava) ||
							(world.is_water(w, bx, by + 1, bz) &&
							world.wid(w, bx, by + 1, bz) != lava);
				};
				auto in_lava = [&](float x, float y, float z){
					const int bx = (int)std::floor(x + 0.5f),
							by = (int)std::floor(y + 0.5f),
							bz = (int)std::floor(z + 0.5f);
					if(world.wid(w, bx, by, bz) != lava &&
							world.wid(w, bx, by + 1, bz) != lava){
						m.lava_t = 0;
						return;
					}
					m.lava_t += dt;
					if(m.lava_t >= 1){
						m.lava_t = 0;
						log_i(MODULE, "skeldat: the %s (%u) burns in lava",
								MOB_KIND[m.kind], key);
						harmed.push_back({key, hazards::LAVA_HARM});
					}
				};
				if(m.kind == SKELETON){
					// The light form decides (step_light()); here the
					// fight's sight and bow, and the body after it
					if(p && d < 16){
						// Its first sight of a player: a marker skull, one
						// a game day ([SKELDAT_SKELETON_SIM])
						// [SKELDAT_BOAT_FAULTS] None from a boat: where it
						// goes is somewhere skeletons may not have been
						if(!tg.is_mob && m.mode != FIGHT && !growth.ended &&
								!m.boat){
							int at[3];
							if(world.t / world.day_s - m.marker_day < 1.0 / growth.speed)
								log_i(MODULE, "skeldat: a skeleton (%u) sees "
										"%s, its marker placed today", key,
										cs(p->name));
							else if(marker_spot(w, m, at)){
								marks.push_back({key, {at[0], at[1], at[2]},
										p->name});
								m.marker_day = world.t / world.day_s;
							}
						}
						fight();
					} else {
						let_go(key, m, "the player out of 16");
						if(m.mode == FIGHT)
							m.mode = WANDER;
					}
					// [SKELDAT_BOATS] On a boat: the body on the light form
					// at the body's speed, over the water; no drowning, no sun
					if(m.boat){
						const float dx = m.x - m.bx, dz = m.z - m.bz,
								flat = std::sqrt(dx * dx + dz * dz);
						const float k = flat > 0 ? std::min(1.0f, BODY_SPEED * dt / flat) : 1;
						m.bx += dx * k, m.bz += dz * k, m.by = m.y;
						if(flat > 0.05f && !(p && m.mode == FIGHT))
							m.yaw = std::atan2(dx, dz);
						continue;
					}
					step_body(w, m, p, dt);
					// [SKELDAT_SKELETON_WATER] Its body in water, the feet's
					// voxel or the one over them: dead at once
					if(in_water(m.bx, m.by, m.bz)){
						drowned.push_back(key);
						continue;
					}
					in_lava(m.bx, m.by, m.bz);
					// The sun burns it, unless bones are round its light
					// form
					burns(m.x, m.y, m.z);
					continue;
				}
				// [SKELDAT_CAVE_SKELETON] A cave skeleton in a fight stands,
				// turned to its target; out of it, a boar's wander
				bool stands = false, to_spot = false;
				if(m.kind == CAVE_SKELETON){
					if(p && d < 16){
						fight();
						m.yaw = std::atan2(p->x - m.x, p->z - m.z);
						stands = true;
						// [SKELDAT_CLEAR_SHOT] No route search: a spot with
						// a clear shot walked to straight, for 3 s at most
						if(m.no_shot && world.t >= m.shot_try_t){
							m.shot_try_t = world.t + SHOT_WAIT;
							m.no_shot = false;
							int at[3];
							const bool found = shot_spot(w, m, *p, at);
							log_shot_try(key, m, *p, found ? at : nullptr, "no spot");
							if(found)
								m.spot_x = (float)at[0], m.spot_z = (float)at[2],
								m.spot_t = world.t + 3;
						}
						if(world.t < m.spot_t){
							if(std::hypot(m.spot_x - m.x, m.spot_z - m.z) < 0.3f)
								m.spot_t = 0;
							else
								stands = false, to_spot = true;
						}
					} else {
						let_go(key, m, "the target out of 16");
						if(m.mode == FIGHT)
							m.mode = WANDER, m.mode_t = 0;
					}
				}
				float move_yaw = m.yaw, speed = 0;
				if(stands){
				} else if(to_spot){
					move_yaw = std::atan2(m.spot_x - m.x, m.spot_z - m.z);
					speed = MOB_SPEED[m.kind][0];
				} else if(m.mode == FLEE && m.mode_t > 0){
					m.yaw = move_yaw = std::atan2(m.x - m.from_x, m.z - m.from_z);
					speed = MOB_SPEED[m.kind][1];
				} else {
					if(m.mode != WANDER || m.mode_t <= 0){
						m.mode = WANDER;
						m.mode_t = 3 + world.rnd() * 4;
						m.speed = world.rnd() < 0.5f ? 0 : MOB_SPEED[m.kind][0];
						m.yaw = world.rnd() * 2 * (float)M_PI;
					}
					move_yaw = m.yaw, speed = m.speed;
				}
				// [SKELDAT_BOAR_SWIM] A boar in water swims at half its
				// walk; a quarter day in, it swims for dry ground, and over
				// deep water for a shallower column; out of it, deep water
				// turns it as a wall does, and after a swim back any water
				// for a while
				const int fx = (int)std::floor(m.x + 0.5f),
						fy = (int)std::floor(m.y + 0.5f),
						fz = (int)std::floor(m.z + 0.5f);
				const int depth = m.kind == BOAR ? water_depth(w, fx, fy, fz) : 0;
				const bool wet = depth > 0 && world.is_water(w, fx, fy, fz) &&
						world.wid(w, fx, fy, fz) != lava;
				bool heading = false;
				if(m.kind == BOAR){
					const uint8_t was = m.water;
					m.water = !wet ? 0 : depth >= DEEP_WATER ? 2 : 1;
					if(was == 0 && m.water)
						log_i(MODULE, "skeldat: the boar (%u) swims, the water %d deep",
								key, depth);
					if(was == 1 && m.water == 2)
						log_i(MODULE, "skeldat: the boar (%u) is over deep water",
								key);
					if(!wet){
						if(was)
							log_i(MODULE, "skeldat: the boar (%u) is out of the water "
									"after %.0f s", key, world.t - m.dry_t);
						if(world.t - m.dry_t > BOAR_SWIM_DAYS * world.day_s)
							m.stay_t = world.t + BOAR_STAY_DAYS * world.day_s;
						m.dry_t = world.t;
						m.floated = false;
					}
					const bool shore = wet &&
							world.t - m.dry_t > BOAR_SWIM_DAYS * world.day_s;
					if((shore || (wet && depth >= DEEP_WATER)) && m.mode != FLEE){
						if(world.t >= m.swim_t){
							const bool was_to = m.swim_to;
							m.swim_t = world.t + 2;
							m.swim_to = boar_column(w, m, shore, &m.swim_x, &m.swim_z);
							if(m.swim_to && (!was_to || m.swim_dry != shore))
								log_i(MODULE, "skeldat: the boar (%u) swims for %s at "
										"%.0f,%.0f", key, shore ? "dry ground" :
										"shallower water", m.swim_x, m.swim_z);
							m.swim_dry = shore;
						}
						if(m.swim_to){
							m.yaw = move_yaw = std::atan2(m.swim_x - m.x, m.swim_z - m.z);
							speed = MOB_SPEED[BOAR][0];
							heading = true;
						}
					} else
						m.swim_to = false, m.swim_t = 0;
					if(wet)
						speed *= 0.5f;
				}
				// Where it can go: a step up, or down to a fall; a wall or a
				// drop past three turns it
				const float nx = m.x + std::sin(move_yaw) * speed * dt,
						nz = m.z + std::cos(move_yaw) * speed * dt;
				Ground to;
				const Ground *under = &here;
				const int nfx = (int)std::floor(nx + 0.5f),
						nfz = (int)std::floor(nz + 0.5f);
				bool keep_out = false, swims_on = false;
				if(m.kind == BOAR && speed > 0 && (nfx != fx || nfz != fz)){
					const int nd = water_depth(w, nfx, fy, nfz);
					keep_out = !heading && m.mode != FLEE && nd > 0 &&
							((nd >= DEEP_WATER && depth < DEEP_WATER) ||
							(!wet && world.t < m.stay_t));
					swims_on = wet && world.is_water(w, nfx, fy, nfz) &&
							world.wid(w, nfx, fy, nfz) != lava;
				}
				if(keep_out){
					if(m.mode == WANDER)
						m.yaw = world.rnd() * 2 * (float)M_PI;
				} else if(speed > 0){
					to = world.ground(w, nx, m.y, nz, h);
					if(swims_on && !(to.found && to.y <= m.y + 1.01f && to.y > m.y)){
						m.x = nx, m.z = nz;
					} else if(to.found && to.y <= m.y + 1.01f){
						m.x = nx, m.z = nz;
						m.y = std::max(m.y, to.y);
						under = &to;
					} else if(m.mode == WANDER)
						m.yaw = world.rnd() * 2 * (float)M_PI;
				}
				// [SKELDAT_BOAR_SWIM] A boar over water floats, its back at
				// the top, bobbing: down to it as it falls, up to it slower
				int top = 0;
				float float_y = -1e9f;
				if(m.kind == BOAR){
					const int cx = (int)std::floor(m.x + 0.5f),
							cz = (int)std::floor(m.z + 0.5f);
					if(water_depth(w, cx, (int)std::floor(m.y + 0.5f), cz, &top) > 0 &&
							top >= (int)std::floor(m.y + 0.5f) - 1)
						float_y = top + 0.5f - BOAR_FLOAT +
								0.04f * std::sin((float)world.t * 2.5f + key);
				}
				const bool floats = float_y > -1e8f &&
						(!under->found || float_y > under->y);
				if(floats && m.y <= float_y + 0.001f){
					m.vy = 0;
					m.y = std::min(float_y, m.y + 1.5f * dt);
					if(!m.floated && m.y >= float_y - 0.05f){
						m.floated = true;
						log_i(MODULE, "skeldat: the boar (%u) floats, its feet at "
								"%.2f, the water's top at %d", key, m.y, top);
					}
				} else if(under->found || floats){
					const float rest = floats ? float_y : under->y;
					if(m.y > rest + 0.001f){
						m.vy -= GRAVITY * dt;
						m.y = std::max(rest, m.y + m.vy * dt);
					}
					if(m.y <= rest)
						m.vy = 0;
				} else {
					m.vy -= GRAVITY * dt;
					m.y += m.vy * dt;
				}
				if(m.kind == CAVE_SKELETON){
					m.bx = m.x, m.by = m.y, m.bz = m.z;
					if(in_water(m.x, m.y, m.z))
						drowned.push_back(key);
					else {
						burns(m.x, m.y, m.z);
						in_lava(m.x, m.y, m.z);
					}
					continue;
				}
				if(m.y < -1000)
					burnt.push_back({key, 1000});
				// [SKELDAT_MINING_HAZARDS] Lava and gas hurt a boar as a
				// player, a second at a time
				m.burn_t += dt;
				if(m.burn_t >= 1){
					m.burn_t = 0;
					const int x = (int)std::floor(m.x + 0.5f),
							y = (int)std::floor(m.y + 0.5f),
							z = (int)std::floor(m.z + 0.5f);
					const char *how = "";
					const int harm = world.harm(world.wid(w, x, y, z),
							world.wid(w, x, y + 1, z), world.format.param.get(
							w->get_voxel(pv::Vector3DInt32(x, y + 1, z), true).data),
							&how);
					if(harm > 0){
						log_i(MODULE, "skeldat: the boar (%u) %s", key, how);
						harmed.push_back({key, harm});
					}
				}
				// [SKELDAT_BOAR_GRASS] Its grass clock: the voxel under the
				// feet grass sets it; a game day off grass and it dies
				// simplified: the clock runs dormant too, read when active
				if(world.wid(w, (int)std::floor(m.x + 0.5f),
						(int)std::floor(m.y + 0.51f) - 1,
						(int)std::floor(m.z + 0.5f)) == world.id_of("skeldat:grass"))
					m.grass_t = world.t;
				else if(world.t - m.grass_t > world.day_s)
					off_grass.push_back(key);
				// [SKELDAT_BOAR_SWIM] In the water since before the last
				// sunset: gone at sunrise
				else if(wet && world.day >= 0.25 && world.day < 0.75 &&
						m.dry_t <= world.t - (world.day + 0.25) * world.day_s)
					wet_night.push_back(key);
			}
		});
		for(uint32_t key : active){
			auto it = all.find(key);
			pv::Vector3DInt32 at;
			if(it != all.end() && it->second.kind == SKELETON &&
					it->second.carry_coal < 0 &&
					furnaces.lantern_at_hand(it->second.x, it->second.y, it->second.z, at))
				take_lantern(key, it->second, at);
		}
		for(const Mark &k : marks){
			world.set_node(k.p[0], k.p[1], k.p[2], world.marker);
			log_i(MODULE, "skeldat: a skeleton (%u) places a marker skull at "
					"%d,%d,%d on seeing %s", k.key, k.p[0], k.p[1], k.p[2],
					cs(k.seen));
		}
		// The target as it is now: a player still there, a mob still alive
		auto now = [&](Target &t){
			if(t.is_mob){
				auto o = all.find(t.mob);
				if(o == all.end())
					return false;
				t.x = o->second.bx, t.y = o->second.by, t.z = o->second.bz;
				return true;
			}
			auto p = players.find(t.peer);
			if(p == players.end())
				return false;
			t.x = p->second.x, t.y = p->second.y, t.z = p->second.z;
			return true;
		};
		for(auto &s : draws){
			auto m = all.find(s.first);
			if(m == all.end() || !now(s.second))
				continue;
			host.sound("bow_draw", m->second.bx, m->second.by + 1.5f, m->second.bz);
			log_i(MODULE, "skeldat: a %s (%u) draws at %s",
					MOB_KIND[m->second.kind], s.first, cs(s.second.name));
		}
		for(auto &s : shots){
			auto m = all.find(s.first);
			if(m == all.end() || !now(s.second))
				continue;
			// From the body
			Mob b = m->second;
			b.x = b.bx, b.y = b.by, b.z = b.bz;
			shoot(b, s.second);
		}
		for(uint32_t key : drowned){
			log_i(MODULE, "skeldat: the %s (%u) is in water",
					MOB_KIND[all[key].kind], key);
			Mob &m = all[key];
			m.x = m.bx, m.y = m.by, m.z = m.bz;
			damage(key, 1000, NOBODY, 0, 0, true);
		}
		// No drops, no hurt: removed with its death sound
		for(uint32_t key : off_grass)
			vanish(key, "dies off the grass");
		for(uint32_t key : wet_night)
			vanish(key, "spent the night in water");
		for(auto &b : burnt){
			if(!all.count(b.first))
				continue;
			if(b.second < 1000)
				log_i(MODULE, "skeldat: the %s (%u) burns",
						MOB_KIND[all[b.first].kind], b.first);
			damage(b.first, b.second, NOBODY, 0, 0);
		}
		for(auto &b : harmed)
			if(all.count(b.first))
				damage(b.first, b.second, NOBODY, 0, 0);
		main_context::access(world.server, world.scene, [&](Urho3D::Scene *scene){
			for(auto &kv : all){
				Mob &m = kv.second;
				Urho3D::Node *n = m.node_id ? scene->GetNode(m.node_id) : nullptr;
				if(!n)
					continue;
				if(m.kind == SKELETON)
					n->SetPosition(Urho3D::Vector3(m.bx, m.by, m.bz));
				else
					n->SetPosition(Urho3D::Vector3(m.x, m.y, m.z));
				n->SetRotation(Urho3D::Quaternion(m.yaw * M_RADTODEG,
						Urho3D::Vector3::UP));
				if(m.hurt != m.hurt_sent){
					n->SetVar(Urho3D::StringHash("skeldat_hurt"),
							Urho3D::Variant(m.hurt));
					m.hurt_sent = m.hurt;
				}
				if((int)m.boat != m.boat_sent){
					n->SetVar(Urho3D::StringHash("skeldat_boat"),
							Urho3D::Variant((int)m.boat));
					m.boat_sent = m.boat;
				}
				const int drawing = m.draw_t >= 0;
				if(drawing != m.draw_sent){
					n->SetVar(Urho3D::StringHash("skeldat_draw"),
							Urho3D::Variant(drawing));
					m.draw_sent = drawing;
				}
			}
		});
	}

	// A light skeleton on a random column past DORMANT_PAST of every player: on
	// one at FLOOD, its footprint picked by its flooded columns, or
	// anywhere (on_bones false)
	bool add_skeleton(bool on_bones)
	{
		const int S = skeldat::bones::SECTION;
		int64_t total = 0;
		for(int n : growth.flooded)
			total += n;
		if(on_bones && total == 0)
			return false;
		size_t i = world.rand() % world.footprints();
		if(on_bones){
			int64_t r = (int64_t)(world.rand() % (uint64_t)total);
			for(i = 0; r >= growth.flooded[i]; i++)
				r -= growth.flooded[i];
		}
		const int x = ((int)(i % (2 * world.half)) - world.half) * S + world.rand() % S,
				z = ((int)(i / (2 * world.half)) - world.half) * S + world.rand() % S;
		const long c = world.column(x, z);
		if(c < 0 || world.top_y[c] == NO_GROUND ||
				(on_bones && world.top_b[c] < skeldat::bones::FLOOD))
			return false;
		const float y = world.top_y[c] + 0.5f;
		float d;
		host.nearest((float)x, y, (float)z, d);
		if(d < DORMANT_PAST)
			return false;
		Mob m;
		m.kind = SKELETON;
		m.x = (float)x, m.y = y, m.z = (float)z;
		m.hp = MOB_HP[SKELETON];
		m.yaw = world.rnd() * 2 * (float)M_PI;
		m.light_t = world.rnd() * light_step;
		m.grass_t = world.t;
		all[next_mob++] = m;
		return true;
	}

	// The nearest column to (x, z) within SEED_RANGE, not (x, z), whose
	// top is ground with no bones and air above, inside the nine footprints
	// round `fp`
	// simplified: SEED_RANGE, not the whole nine footprints, for the cost
	// of 2000 searches at sunset
	bool clean_column(int x, int z, long fp, int &ox, int &oz)
	{
		const int w = 2 * world.half;
		for(int r = 1; r <= SEED_RANGE; r++)
		for(int dz = -r; dz <= r; dz++)
		for(int dx = -r; dx <= r; dx += (std::abs(dz) == r ? 1 : 2 * r)){
			const long c = world.column(x + dx, z + dz), f = world.footprint(x + dx, z + dz);
			if(c < 0 || world.top_y[c] == NO_GROUND || world.top_b[c] != 0 ||
					world.top_y[c] >= (world.y1 + 1) * skeldat::bones::SECTION - 1 ||
					std::abs(f % w - fp % w) > 1 || std::abs(f / w - fp / w) > 1)
				continue;
			ox = x + dx, oz = z + dz;
			return true;
		}
		return false;
	}

	// [SKELDAT_BRIDGES_SEEN] The goal walk's waypoint: the ground column
	// (not water) nearest the point WAYPOINT columns along the
	// straight line from x, z to tx, tz (or tx, tz if nearer), within 6 of
	// it; tx, tz and ty (its top + 1, the feet) set to it. Left as they
	// are, ty unset, with none. simplified: nearest the point, not the line
	void waypoint(int x, int z, int &tx, int &tz, int &ty)
	{
		const float dx = (float)(tx - x), dz = (float)(tz - z);
		const float d = std::sqrt(dx * dx + dz * dz);
		const float k = d > WAYPOINT ? WAYPOINT / d : 1;
		const int px = x + (int)std::lround(dx * k),
				pz = z + (int)std::lround(dz * k);
		for(int r = 0; r <= 6; r++)
		for(int oz = -r; oz <= r; oz++)
		for(int ox = -r; ox <= r;
				ox += (r == 0 || std::abs(oz) == r) ? 1 : 2 * r){
			const long c = world.column(px + ox, pz + oz);
			if(c < 0 || world.top_y[c] == NO_GROUND)
				continue;
			tx = px + ox, tz = pz + oz, ty = world.top_y[c] + 1;
			return;
		}
	}

	// [SKELDAT_BOATS] The green skulls, kept by the voxel (main.cpp's
	// on_set): "x,y,z" keys, saved as "green_skulls"
	std::set<ss_> green;
	uint32_t green_id = ID_IGNORE;
	void green_init()
	{
		green_id = world.id_of("skeldat:green_skull");
		ss_ v;
		if(store && store->get("green_skulls", v)){
			std::istringstream is(v);
			ss_ k;
			while(is>>k)
				green.insert(k);
		}
		for(auto &kv : all)
			if(kv.second.boat)
				log_i(MODULE, "skeldat: a skeleton (%u) on a boat at %.0f,%.0f, "
						"aim %.2f", kv.first, kv.second.x, kv.second.z, kv.second.aim);
	}
	void green_set(int x, int y, int z, uint32_t old, uint32_t id)
	{
		if(old == id || (old != green_id && id != green_id))
			return;
		if(id == green_id)
			green.insert(pos_key(x, y, z));
		else
			green.erase(pos_key(x, y, z));
		ss_ v;
		for(const ss_ &k : green)
			v += k + " ";
		if(store)
			store->set("green_skulls", v);
	}
	bool water_top(int x, int z) const
	{
		const long c = world.column(x, z);
		return c >= 0 && world.top_w[c];
	}
	bool land_top(int x, int z) const
	{
		const long c = world.column(x, z);
		return c >= 0 && world.top_y[c] != NO_GROUND;
	}
	// Stuck by water at (x, z): a water top within 2, and from it a ray
	// (every 45 degrees) over BOAT_ACROSS water tops with no land
	bool stuck_by_water(int x, int z) const
	{
		for(int d = 0; d < 8; d++){
			const int sx = (d == 0 || d == 1 || d == 7) - (d >= 3 && d <= 5),
					sz = (d >= 1 && d <= 3) - (d >= 5 && d <= 7);
			int k = 1;
			while(k <= 2 && !water_top(x + sx * k, z + sz * k))
				k++;
			if(k > 2)
				continue;
			int n = 0;
			while(n < BOAT_ACROSS && water_top(x + sx * (k + n), z + sz * (k + n)))
				n++;
			if(n == BOAT_ACROSS)
				return true;
		}
		return false;
	}
	// At sunrise: each bone skeleton's count of sunrises stuck by water,
	// and at BOAT_DAYS a green skull beside it
	void boats_sunrise()
	{
		sv_<std::pair<uint32_t, vp::P>> skulls;
		for(auto &kv : all){
			Mob &m = kv.second;
			if(m.kind != SKELETON || m.boat)
				continue;
			const int mx = (int)std::floor(m.x + 0.5f), mz = (int)std::floor(m.z + 0.5f);
			if(!stuck_by_water(mx, mz)){
				m.shore_days = 0;
				continue;
			}
			if(++m.shore_days < BOAT_DAYS)
				continue;
			m.shore_days = 0;
			bool near = false;
			for(const ss_ &k : green){
				int x, y, z;
				if(sscanf(k.c_str(), "%d,%d,%d", &x, &y, &z) == 3 &&
						std::abs(x - mx) <= GREEN_SKULL_APART &&
						std::abs(z - mz) <= GREEN_SKULL_APART)
					near = true;
			}
			for(auto &s : skulls)
				near = near || (std::abs(s.second.x - mx) <= GREEN_SKULL_APART &&
						std::abs(s.second.z - mz) <= GREEN_SKULL_APART);
			int at[3];
			bool found = false;
			if(!near)
				voxelworld::access(world.server, world.scene, [&](voxelworld::Instance *w){
					found = marker_spot(w, m, at);
				});
			if(found)
				skulls.push_back({kv.first, vp::P(at[0], at[1], at[2])});
		}
		for(auto &s : skulls){
			world.set_node(s.second.x, s.second.y, s.second.z, green_id);
			log_i(MODULE, "skeldat: a skeleton (%u) places a green skull at "
					"%d,%d,%d", s.first, s.second.x, s.second.y, s.second.z);
		}
	}
	// At sunset: the boats' new aims (not the ones boarding now), then
	// each green skull's one skeleton onto a boat
	void boats_sunset()
	{
		for(auto &kv : all)
			if(kv.second.boat){
				kv.second.aim = world.rnd() * 2 * (float)M_PI;
				log_i(MODULE, "skeldat: a skeleton (%u) on a boat aims %.2f",
						kv.first, kv.second.aim);
			}
		const std::set<ss_> skulls = green;
		for(const ss_ &k : skulls){
			int x, y, z;
			if(sscanf(k.c_str(), "%d,%d,%d", &x, &y, &z) != 3)
				continue;
			// The water within BOAT_NEAR: the nearest for the boat; within 6
			// their mean, the aim away from the shore
			int wx = 0, wz = 0, best = 1 << 30;
			float ax = 0, az = 0;
			for(int dz = -6; dz <= 6; dz++)
			for(int dx = -6; dx <= 6; dx++){
				if(!water_top(x + dx, z + dz))
					continue;
				ax += dx, az += dz;
				const int d = dx * dx + dz * dz;
				if(std::max(std::abs(dx), std::abs(dz)) <= BOAT_NEAR && d < best)
					best = d, wx = x + dx, wz = z + dz;
			}
			if(best == 1 << 30)
				continue;
			uint32_t key = 0;
			float kd = 1e9f;
			for(auto &kv : all){
				const Mob &m = kv.second;
				const float d = std::hypot(m.x - x, m.z - z);
				if(m.kind == SKELETON && !m.boat && d <= BOAT_NEAR && d < kd)
					kd = d, key = kv.first;
			}
			if(kd > BOAT_NEAR)
				continue;
			Mob &m = all[key];
			m.boat = true;
			m.aim = std::atan2(ax, az);
			m.boat_x = (float)x, m.boat_z = (float)z;
			m.boarded_t = world.t;
			m.x = (float)wx, m.z = (float)wz;
			m.y = world.top_any[world.column(wx, wz)] + 0.5f;
			m.route.clear();
			m.shelter_route = m.shot_route = false;
			log_i(MODULE, "skeldat: a skeleton (%u) takes to a boat at %d,%d, "
					"aim %.2f", key, wx, wz, m.aim);
		}
		// [SKELDAT_SKULL_CALL] The called that did not make it, let go
		for(auto &kv : all){
			Mob &m = kv.second;
			if(!m.called)
				continue;
			m.called = m.call_route = false;
			if(!m.boat)
				log_i(MODULE, "skeldat: a called skeleton (%u) did not make it, "
						"%.0f from %d,%d, %d searches%s", kv.first,
						std::hypot(m.x - m.call_at.x, m.z - m.call_at.z),
						m.call_at.x, m.call_at.z, m.call_tries,
						m.call_sheltered ? ", sheltered" : "");
		}
	}
	// [SKELDAT_SKULL_CALL] An hour before sunset: each green skull calls the
	// nearest boatless bone skeleton within BOAT_CALL not called already to
	// its water side, the nearest land top beside a water top within 2
	void boats_call()
	{
		for(const ss_ &k : green){
			int x, y, z;
			if(sscanf(k.c_str(), "%d,%d,%d", &x, &y, &z) != 3)
				continue;
			int sx = 0, sz = 0, best = 1 << 30;
			for(int dz = -2; dz <= 2; dz++)
			for(int dx = -2; dx <= 2; dx++){
				const int ax = x + dx, az = z + dz, d = dx * dx + dz * dz;
				if((dx || dz) && d < best && land_top(ax, az) && !water_top(ax, az) &&
						(water_top(ax + 1, az) || water_top(ax - 1, az) ||
						water_top(ax, az + 1) || water_top(ax, az - 1)))
					best = d, sx = ax, sz = az;
			}
			if(best == 1 << 30)
				continue;
			// [SKELDAT_BOAT_FAULTS] The nearest with a way there: the nearest
			// alone was often across water or up a cliff from it, and stood
			// where it was called until sunset. One within BOAT_NEAR boards
			// without walking.
			const vp::P at(sx, world.top_y[world.column(sx, sz)] + 1, sz);
			std::vector<std::pair<float, uint32_t>> near;
			for(auto &kv : all){
				const Mob &m = kv.second;
				const float d = std::hypot(m.x - x, m.z - z);
				if(m.kind == SKELETON && !m.boat && !m.called && d <= BOAT_CALL)
					near.push_back({d, kv.first});
			}
			std::sort(near.begin(), near.end());
			uint32_t key = 0;
			float kd = 1e9f;
			bool way = false;
			for(size_t i = 0; i < near.size() && i < BOAT_CALL_TRIES; i++){
				Mob &m = all[near[i].second];
				way = near[i].first > BOAT_NEAR &&
						search_way(near[i].second, m, at, BUILD_CAP, false);
				if(way || near[i].first <= BOAT_NEAR){
					kd = near[i].first, key = near[i].second;
					break;
				}
			}
			if(kd > BOAT_CALL){
				if(!near.empty())
					log_i(MODULE, "skeldat: a green skull at %d,%d,%d calls no "
							"skeleton: none of the %zu nearest of %zu within %d "
							"has a way to %d,%d,%d", x, y, z, std::min(near.size(),
							BOAT_CALL_TRIES), near.size(), BOAT_CALL, at.x, at.y,
							at.z);
				continue;
			}
			Mob &m = all[key];
			m.called = true;
			m.call_at = at;
			// The way searched is its route already
			m.call_route = way;
			if(way)
				m.shelter_route = m.shot_route = false;
			m.call_sheltered = false;
			m.call_t = 0;
			m.call_tries = 0;
			log_i(MODULE, "skeldat: a green skull at %d,%d,%d calls a skeleton "
					"(%u), %.0f away", x, y, z, key, kd);
		}
	}
	// [SKELDAT_BOAT_FAULTS] The bones a boat of `days` lands on: under
	// BOAT_BARE_DAYS none, under BOAT_BONED_DAYS any but a bone block,
	// then any
	static bool boat_shore_ok(int top_b, double days)
	{
		return days >= BOAT_BONED_DAYS || top_b == 0 ||
				(days >= BOAT_BARE_DAYS && top_b < skeldat::bones::FLOOD);
	}
	// A boat's light step: at night beside a shore it may land on (by its
	// age, boat_shore_ok()) out of BOAT_HOME of where it boarded, onto it;
	// by day waiting there; else a step on the water toward such a shore
	// seen within BOAT_SHORE, or its aim
	void step_boat(uint32_t key, Mob &m)
	{
		const int mx = (int)std::floor(m.x + 0.5f), mz = (int)std::floor(m.z + 0.5f);
		const double days = (world.t - m.boarded_t) / world.day_s;
		// The shore column seen (land beside water) it may land on, the
		// barest and then the nearest
		int sx = 0, sz = 0, sd = 1 << 30, sb = 0;
		for(int dz = -BOAT_SHORE; dz <= BOAT_SHORE; dz++)
		for(int dx = -BOAT_SHORE; dx <= BOAT_SHORE; dx++){
			const int x = mx + dx, z = mz + dz;
			if(!land_top(x, z) || std::hypot(x - m.boat_x, z - m.boat_z) < BOAT_HOME)
				continue;
			if(!water_top(x + 1, z) && !water_top(x - 1, z) &&
					!water_top(x, z + 1) && !water_top(x, z - 1))
				continue;
			const int b = world.top_b[world.column(x, z)];
			if(!boat_shore_ok(b, days))
				continue;
			const int d = dx * dx + dz * dz;
			if(sd == 1 << 30 || b < sb || (b == sb && d < sd))
				sd = d, sx = x, sz = z, sb = b;
		}
		if(sd <= 2){
			// Waiting by day beside the shore it means to land on
			if(sun_danger())
				return;
			m.boat = false;
			m.x = (float)sx, m.z = (float)sz;
			m.y = world.top_y[world.column(sx, sz)] + 0.5f;
			log_i(MODULE, "skeldat: a skeleton (%u) lands at (%d %d)%s, "
					"%.1f days on its boat", key, sx, sz, sb == 0 ? "" :
					sb >= skeldat::bones::FLOOD ? ", a bone block" :
					", a shore with bones", days);
			return;
		}
		const float want = sd < (1 << 30) ? std::atan2((float)(sx - mx),
				(float)(sz - mz)) : m.aim;
		for(int t = 0; t < 6; t++){
			const float yaw = want + (world.rnd() - 0.5f) * (t == 0 ? 0.6f :
					2 * (float)M_PI);
			const int x = (int)std::floor(m.x + std::sin(yaw) + 0.5f),
					z = (int)std::floor(m.z + std::cos(yaw) + 0.5f);
			if((x == mx && z == mz) || !water_top(x, z))
				continue;
			m.yaw = yaw;
			m.x = (float)x, m.z = (float)z;
			m.y = world.top_any[world.column(x, z)] + 0.5f;
			return;
		}
	}

	// At sunrise and sunset each skeleton picks, of its footprint and the
	// eight round it, the one with the most marker skulls: its own on a
	// tie, a random one when all have none; at sunset its night's bone
	// blocks too
	void pick_footprints(bool sunset)
	{
		const int w = 2 * world.half;
		size_t moving = 0, n = 0;
		// What lures: the marker skulls, and a burning lantern as
		// LANTERN_LURE of them
		sv_<int> lure = markers;
		for(auto &pair : furnaces.lanterns_by_footprint())
			lure[pair.first] += LANTERN_LURE * (int)pair.second.size();
		if(sunset)
			boats_sunset();
		else
			boats_sunrise();
		for(auto &kv : all){
			Mob &m = kv.second;
			// [SKELDAT_BOAT_FAULTS] The markers draw no boat
			if(m.kind != SKELETON || m.boat)
				continue;
			n++;
			const long own = world.footprint((int)std::floor(m.x + 0.5f),
					(int)std::floor(m.z + 0.5f));
			if(own < 0)
				continue;
			long best = own;
			sv_<long> around;
			for(int dz = -1; dz <= 1; dz++)
			for(int dx = -1; dx <= 1; dx++){
				const long fx = own % w + dx, fz = own / w + dz;
				if(fx < 0 || fx >= w || fz < 0 || fz >= w)
					continue;
				around.push_back(fz * w + fx);
				if(lure[fz * w + fx] > lure[best])
					best = fz * w + fx;
			}
			if(lure[best] == 0)
				best = around[world.rand() % around.size()];
			m.goal_fp = (int)best;
			moving += best != own;
			m.quota = sunset ? (1 + world.rand() % NIGHT_BLOCKS) * growth.speed : 0;
			m.seeding = false;
		}
		long most = 0;
		for(size_t i = 0; i < world.footprints(); i++)
			if(lure[i] > lure[most])
				most = (long)i;
		size_t there = 0;
		for(auto &kv : all)
			there += kv.second.kind == SKELETON && world.footprint(
					(int)std::floor(kv.second.x + 0.5f),
					(int)std::floor(kv.second.z + 0.5f)) == most;
		log_i(MODULE, "skeldat: %s: %zu of %zu skeletons to another "
				"footprint; the one with the most markers (%d, at %ld %ld) has "
				"%zu; %zu bone blocks placed since", sunset ? "sunset" :
				"sunrise", moving, n, lure[most], most % w - world.half,
				most / w - world.half, there, night_blocks);
		night_blocks = 0;
	}

	// Every light skeleton a column each light step, on the top map: at
	// night to its next clean column and a bone block there, else to its
	// footprint, else wandering inside it; on, or a new heading where the
	// next column's top is not within one up and two down
	// [SKELDAT_SURFACE_END] A skeleton's step at (x, z): a deep hole
	// within 2 columns (bones.h's deep_hole(), on the column tops) gets a
	// skull dropped into it in one of HOLE_ONE_IN, at most once a game day
	// a hole; from the lowest rim's height, falling as a drop does
	void drop_into_holes(int x, int z)
	{
		// Once in 1/speed of a day, each step's chance times the speed
		const int day = (int)(world.t / world.day_s * growth.speed);
		for(int dz = -2; dz <= 2; dz++)
		for(int dx = -2; dx <= 2; dx++){
			const long c = world.column(x + dx, z + dz);
			if(c < 0 || world.top_y[c] == NO_GROUND || world.top_b[c] != 0)
				continue;
			int around[8], n = 0;
			for(int bz = -1; bz <= 1; bz++)
			for(int bx = -1; bx <= 1; bx++){
				if(bx == 0 && bz == 0)
					continue;
				const long b = world.column(x + dx + bx, z + dz + bz);
				around[n++] = b < 0 || world.top_y[b] == NO_GROUND ? NO_GROUND :
						world.top_y[b];
			}
			if(!skeldat::bones::deep_hole(world.top_y[c], 0, around))
				continue;
			auto it = hole_day.find(c);
			if((it != hole_day.end() && it->second == day) ||
					world.rand() % skeldat::bones::HOLE_ONE_IN >= (uint32_t)growth.speed)
				continue;
			hole_day[c] = day;
			int rim = around[0];
			for(int v : around)
				rim = std::min(rim, v);
			drops.seed_skull((float)(x + dx), rim + 1.5f, (float)(z + dz));
			log_i(MODULE, "skeldat: a skeleton drops a skull into the hole at "
					"%d,%d,%d", x + dx, world.top_y[c], z + dz);
		}
	}

	// [SKELDAT_SUN_SHELTER] Whether the sun is a danger to a bone skeleton
	// now: from SHELTER_DAWN before sunrise (world.sun()'s 0.23) to sunset
	bool sun_danger() const
	{
		return world.day >= 0.23 - SHELTER_DAWN && world.day <= 0.77;
	}
	// Whether feet at (x, y, z) would burn by day: the voxel's sky light 12
	// or more and no bones round it (world.sun_safe()); for a light form
	// with no body the column top's, under the sky, safe at FLOOD
	bool exposed(const Mob &m, int x, float y, int z)
	{
		if(!m.node_id){
			const long c = world.column(x, z);
			return c >= 0 && world.top_b[c] < skeldat::bones::FLOOD;
		}
		bool out = false;
		voxelworld::access(world.server, world.scene, [&](voxelworld::Instance *w){
			out = exposed_in(w, x, y, z);
		});
		return out;
	}
	bool exposed_in(voxelworld::Instance *w, int x, float y, int z)
	{
		int sky, lamp;
		world.light(w, x, (int)std::floor(y + 0.5f), z, sky, lamp);
		return sky >= 12 && world.sun_safe(w, (float)x, y, (float)z) == 0;
	}
	// Rule 1: a step to (x, y, z) refused while the sun is a danger, the
	// skeleton safe where it stands and the step not
	// simplified: the step's voxel only; a sunlit one between is not read
	bool sun_refuses(const Mob &m, int x, float y, int z)
	{
		if(!sun_danger() || !exposed(m, x, y, z) ||
				exposed(m, (int)std::floor(m.x + 0.5f), m.y,
				(int)std::floor(m.z + 0.5f)))
			return false;
		sun_kept++;
		return true;
	}
	// Rule 2: m out in the sun while it is a danger, at most every
	// SHELTER_WAIT: the nearest feet voxels within SHELTER_RANGE that are
	// not exposed (for a body, on the ground within a step up and three
	// down of its own height; for a light form, column tops at FLOOD), a
	// way searched to each of the first SHELTER_TRIES until one is found
	bool seek_shelter(uint32_t key, Mob &m)
	{
		const int mx = (int)std::floor(m.x + 0.5f), mz = (int)std::floor(m.z + 0.5f);
		if(!sun_danger() || world.t < m.shelter_t || !exposed(m, mx, m.y, mz))
			return false;
		m.shelter_t = world.t + SHELTER_WAIT;
		sv_<vp::P> found;
		// The columns in rings, in one access for a body's voxels
		auto scan = [&](voxelworld::Instance *w){
			for(int r = 1; r <= SHELTER_RANGE && (int)found.size() < SHELTER_TRIES; r++)
			for(int dz = -r; dz <= r && (int)found.size() < SHELTER_TRIES; dz++)
			for(int dx = -r; dx <= r && (int)found.size() < SHELTER_TRIES;
					dx += (std::abs(dz) == r ? 1 : 2 * r)){
				const int x = mx + dx, z = mz + dz;
				if(w){
					const Ground g = world.ground(w, (float)x, m.y, (float)z,
							MOB_HEIGHT[SKELETON]);
					if(g.found && !g.water && !exposed_in(w, x, g.y, z))
						found.push_back(vp::P(x, (int)std::floor(g.y + 1.0f), z));
					continue;
				}
				const long c = world.column(x, z);
				if(c >= 0 && world.top_y[c] != NO_GROUND &&
						world.top_b[c] >= skeldat::bones::FLOOD)
					found.push_back(vp::P(x, world.top_y[c] + 1, z));
			}
		};
		if(m.node_id)
			voxelworld::access(world.server, world.scene, scan);
		else
			scan(nullptr);
		for(const vp::P &at : found)
			if(search_way(key, m, at, SHOT_CAP, false)){
				log_i(MODULE, "skeldat: a skeleton (%u) finds shelter at %d,%d,%d",
						key, at.x, at.y, at.z);
				m.shelter_route = true;
				return true;
			}
		log_i(MODULE, "skeldat: a skeleton (%u) finds no shelter (%zu places "
				"tried)", key, found.size());
		return false;
	}

	void step_light(float dt)
	{
		const int64_t t0 = interface::os::time_us();
		const int S = skeldat::bones::SECTION;
		const uint32_t block = world.id_of("skeldat:bone_block");
		struct Block { int x, y, z; };
		sv_<Block> blocks;
		struct Take { uint32_t key; pv::Vector3DInt32 at; };
		sv_<Take> takes;
		const auto lanterns = furnaces.lanterns_by_footprint();
		// The goal walk's search: the one that waited longest in the last
		// step, if it is refused again (or the first, with none waiting)
		const uint32_t walk_turn = walk_next;
		const bool walk_any = walk_queued;
		walk_queued = false;
		double walk_best = 0;
		auto take_walk_search = [&](uint32_t key, Mob &m){
			if(m.walk_want_t <= 0)
				m.walk_want_t = world.t;
			if(world.t >= walk_search_t && (!walk_any || key == walk_turn)){
				walk_search_t = world.t + WALK_SEARCH_WAIT;
				m.walk_want_t = 0;
				return true;
			}
			if(!walk_queued || m.walk_want_t < walk_best)
				walk_next = key, walk_queued = true, walk_best = m.walk_want_t;
			return false;
		};
		// The light form's next feet at (x, z): the column's top, or for
		// one with a body the ground round its own height (a cave, an
		// overhang), as the body walks; -1e9 for none
		auto next_y = [&](const Mob &m, int x, int z){
			if(m.node_id){
				Ground g;
				voxelworld::access(world.server, world.scene, [&](voxelworld::Instance *w){
					g = world.ground(w, (float)x, m.y, (float)z, MOB_HEIGHT[SKELETON]);
				});
				// Water a wall ([SKELDAT_SKELETON_WATER]); the column tops
				// have none, a water top being NO_GROUND
				return g.found && !g.water ? g.y : -1e9f;
			}
			const long c = world.column(x, z);
			return c < 0 || world.top_y[c] == NO_GROUND ? -1e9f :
					world.top_y[c] + 0.5f;
		};
		for(auto &kv : all){
			Mob &m = kv.second;
			if(m.kind != SKELETON)
				continue;
			// Every skeleton is its light form ([SKELDAT_LIGHT_PRIMARY]);
			// one with a body steps often enough for the body to walk
			const float step = m.node_id ? std::min(NEAR_STEP, light_step) :
					light_step;
			m.light_t = std::min(m.light_t - dt, step);
			if(m.light_t > 0)
				continue;
			m.light_t += step;
			light_steps++;
			const int mx = (int)std::floor(m.x + 0.5f),
					mz = (int)std::floor(m.z + 0.5f);
			// [SKELDAT_BOATS] A boat's own step, every 1/BOAT_SPEED
			if(m.boat){
				m.boat_t += step;
				if(m.boat_t >= step / BOAT_SPEED - 0.001f){
					m.boat_t = 0;
					step_boat(kv.first, m);
				}
				continue;
			}
			if(!growth.ended)
				drop_into_holes(mx, mz);
			// [SKELDAT_SUN_SHELTER] On its way to shelter, or looking for one
			if(m.shelter_route && !m.route.empty()){
				follow_route(kv.first, m);
				continue;
			}
			m.shelter_route = false;
			if(seek_shelter(kv.first, m)){
				// [SKELDAT_BOAT_FAULTS] What keeps a called one from its call
				if(m.called && !m.call_sheltered){
					m.call_sheltered = true;
					log_i(MODULE, "skeldat: a called skeleton (%u) goes to shelter "
							"from the sun, %.0f from %d,%d", kv.first,
							std::hypot(m.x - m.call_at.x, m.z - m.call_at.z),
							m.call_at.x, m.call_at.z);
				}
				m.shot_route = m.call_route = false;
				follow_route(kv.first, m);
				continue;
			}
			// [SKELDAT_SKULL_CALL] Called: on its way to the skull's water,
			// a way searched again after the sun's shelter took it off it,
			// and standing there until sunset
			if(m.called){
				if(m.call_route && !m.route.empty()){
					follow_route(kv.first, m);
					continue;
				}
				m.call_route = false;
				if(std::hypot(m.x - m.call_at.x, m.z - m.call_at.z) > 1.5f &&
						world.t >= m.call_t){
					m.call_t = world.t + SHELTER_WAIT;
					m.call_tries++;
					if(search_way(kv.first, m, m.call_at, BUILD_CAP, false)){
						m.call_route = true;
						log_i(MODULE, "skeldat: a called skeleton (%u) has a way of "
								"%zu to %d,%d,%d", kv.first, m.route.size(),
								m.call_at.x, m.call_at.y, m.call_at.z);
						follow_route(kv.first, m);
					} else if(m.call_tries == 1)
						log_i(MODULE, "skeldat: a called skeleton (%u) at %.0f,%.0f,%.0f "
								"finds no way to %d,%d,%d", kv.first, m.x, m.y, m.z,
								m.call_at.x, m.call_at.y, m.call_at.z);
				}
				continue;
			}
			// Fighting: a bow's distance, between 3 and 9, that a sword's
			// reach can still close
			if(m.node_id && m.mode == FIGHT){
				const Target t = target_of(m);
				const Target *p = t.d < 1e9f ? &t : nullptr;
				const float d = t.d;
				// [SKELDAT_CLEAR_SHOT] On its way to a spot with a clear
				// shot; or, its shot blocked, a try for one
				if(m.shot_route && !m.route.empty()){
					follow_route(kv.first, m);
					continue;
				}
				m.shot_route = false;
				if(p && m.no_shot && world.t >= m.shot_try_t){
					m.shot_try_t = world.t + SHOT_WAIT;
					m.no_shot = false;
					int at[3];
					bool found = false;
					voxelworld::access(world.server, world.scene,
							[&](voxelworld::Instance *w){
						found = shot_spot(w, m, *p, at);
					});
					if(!found)
						log_shot_try(kv.first, m, *p, nullptr, "no spot");
					else if(search_way(kv.first, m, vp::P(at[0], at[1], at[2]),
							SHOT_CAP, false)){
						m.shot_route = true;
						log_shot_try(kv.first, m, *p, at, nullptr);
					} else
						log_shot_try(kv.first, m, *p, nullptr, "no way");
					continue;
				}
				if(!p || (d >= 3 && d <= 9))
					continue;
				m.yaw = std::atan2(p->x - m.x, p->z - m.z) +
						(d < 3 ? (float)M_PI : 0);
				const int x = (int)std::floor(m.x + std::sin(m.yaw) + 0.5f),
						z = (int)std::floor(m.z + std::cos(m.yaw) + 0.5f);
				const float y = next_y(m, x, z);
				if(y <= m.y + 1.01f && y >= m.y - 2.01f && !sun_refuses(m, x, y, z))
					m.x = (float)x, m.z = (float)z, m.y = y;
				continue;
			}
			// With a body and nothing to do, it stands half the time, as
			// a wandering skeleton did
			if(m.node_id && m.goal_fp < 0 && m.quota <= 0 && world.rnd() < 0.5f)
				continue;
			const long own = world.footprint(mx, mz);
			bool to = false;
			int tx = 0, tz = 0;
			// What it must stand next to, for a way built to it: -1e9 for
			// a footprint's middle, which is no such target
			int ty = -1000000000;
			bool goal_walk = false;
			// A burning lantern in its footprint: to it, and taken
			// Or on its way built to one, which may cross out of it
			const bool home = own >= 0 && (own == m.goal_fp ||
					(!m.route.empty() && m.goal_fp >= 0));
			auto lit = lanterns.find(home ? m.goal_fp : own);
			if(m.carry_coal < 0 && home && lit != lanterns.end()){
				const pv::Vector3DInt32 &l = lit->second[0];
				pv::Vector3DInt32 at;
				if(furnaces.lantern_at_hand(m.x, m.y, m.z, at)){
					takes.push_back({kv.first, at});
					continue;
				}
				to = true, tx = l.getX(), tz = l.getZ(), ty = l.getY();
			}
			if(!to && m.quota > 0 && !growth.ended && own >= 0){
				if(!m.seeding && !clean_column(mx, mz, own, m.seed_x,
						m.seed_z))
					m.quota = 0;
				else
					m.seeding = true;
				if(m.seeding && std::abs(m.seed_x - mx) <= 1 &&
						std::abs(m.seed_z - mz) <= 1 &&
						(m.seed_x != mx || m.seed_z != mz)){
					const long c = world.column(m.seed_x, m.seed_z);
					if(world.top_y[c] != NO_GROUND && world.top_b[c] == 0){
						blocks.push_back({m.seed_x, world.top_y[c] + 1, m.seed_z});
						if(m.built)
							log_i(MODULE, "skeldat: a skeleton (%u) places its "
									"night's block at %d,%d,%d, by the way it "
									"built", kv.first, m.seed_x, world.top_y[c] + 1,
									m.seed_z);
					}
					m.built = false;
					m.seeding = false;
					m.quota--;
				} else if(m.seeding){
					to = true, tx = m.seed_x, tz = m.seed_z;
					const long c = world.column(tx, tz);
					if(world.top_y[c] != NO_GROUND)
						ty = world.top_y[c] + 1;
				}
			}
			if(!to && m.goal_fp >= 0 && own != m.goal_fp){
				const int w = 2 * world.half;
				to = true;
				tx = (m.goal_fp % w - world.half) * S + S / 2;
				tz = (m.goal_fp / w - world.half) * S + S / 2;
				// [SKELDAT_BRIDGES_SEEN] Toward a waypoint on the way, which
				// a refused step searches a way to, built if it must be
				waypoint(mx, mz, tx, tz, ty);
				goal_walk = true;
			}
			if(!to || ty < -1000)
				m.route.clear();
			if(!m.route.empty()){
				follow_route(kv.first, m);
				continue;
			}
			if(m.detour > 0)
				m.detour--;
			else if(to)
				m.yaw = std::atan2((float)(tx - mx), (float)(tz - mz)) +
						(world.rnd() - 0.5f) * 0.6f;
			else if(world.rnd() < 0.2f)
				m.yaw = world.rnd() * 2 * (float)M_PI;
			const int x = (int)std::floor(m.x + std::sin(m.yaw) + 0.5f),
					z = (int)std::floor(m.z + std::cos(m.yaw) + 0.5f);
			const float y = next_y(m, x, z);
			// Wandering, it keeps to its footprint
			const bool stray = !to && m.goal_fp >= 0 && own == m.goal_fp &&
					world.footprint(x, z) != m.goal_fp;
			// A step into the sun is a wall's, with no way searched past it
			const bool sunny = !stray && y <= m.y + 1.01f && y >= m.y - 2.01f &&
					sun_refuses(m, x, y, z);
			if(!stray && !sunny && y <= m.y + 1.01f && y >= m.y - 2.01f)
				m.x = (float)x, m.z = (float)z, m.y = y;
			else if(!sunny && to && ty > -1000 && world.t >= m.search_t &&
					(!goal_walk || take_walk_search(kv.first, m)) &&
					search_way(kv.first, m, vp::P(tx, ty, tz)))
				m.detour = 0;
			else {
				m.yaw = world.rnd() * 2 * (float)M_PI;
				if(to)
					m.detour = 4 + world.rand() % 12;
			}
		}
		light_us += interface::os::time_us() - t0;
		for(const Block &b : blocks){
			world.set_node(b.x, b.y, b.z, block, 0, skeldat::bones::MAX);
			night_blocks++;
		}
		for(const Take &t : takes)
			take_lantern(t.key, all[t.key], t.at);
	}

	// [SKELDAT_BONE_BRIDGES] A way for m to stand at goal (a feet voxel):
	// a walking one, or one with bone blocks to build, its route up to the
	// first of them. false for none, and it waits BUILD_WAIT to look again.
	// A light form with no body walks the column tops, so under them is
	// solid to it. A spot's way ([SKELDAT_CLEAR_SHOT]): cap cells at most,
	// no building, search_t left as it is
	bool search_way(uint32_t key, Mob &m, const vp::P &goal,
			size_t cap = BUILD_CAP, bool build = true)
	{
		if(build)
			m.search_t = world.t + BUILD_WAIT;
		vp::P from((int)std::floor(m.x + 0.5f),
				(int)std::floor(m.y + 1.0f), (int)std::floor(m.z + 0.5f));
		// [SKELDAT_BOAT_FAULTS] One with no body is on its column's top: its
		// y lags a column the bones grew under it, which started the search
		// in solid
		if(!m.node_id){
			const long c = world.column(from.x, from.z);
			if(c >= 0 && world.top_y[c] != NO_GROUND)
				from.y = world.top_y[c] + 1;
		}
		if(std::abs(goal.x - from.x) > BUILD_RANGE ||
				std::abs(goal.z - from.z) > BUILD_RANGE)
			return false;
		// The two and 4 round them, 12 under the lower and 8 over the higher
		const int M = 4, DOWN = 12, UP = 8;
		vp::Field f;
		f.resize(vp::P(std::min(from.x, goal.x) - M,
				std::min(from.y, goal.y) - DOWN, std::min(from.z, goal.z) - M),
				std::abs(goal.x - from.x) + 2 * M + 1,
				std::abs(goal.y - from.y) + DOWN + UP + 1,
				std::abs(goal.z - from.z) + 2 * M + 1);
		voxelworld::access(world.server, world.scene, [&](voxelworld::Instance *w){
			world.fill_cells(w, f);
		});
		// Water is no way for a skeleton ([SKELDAT_SKELETON_WATER])
		for(uint8_t &c : f.cells)
			if(c == vp::CLIMB)
				c = vp::LIQUID;
		// One with no body walks the column tops: solid under them
		if(!m.node_id)
			for(int z = f.origin.z; z < f.origin.z + f.d; z++)
			for(int x = f.origin.x; x < f.origin.x + f.w; x++){
				const long c = world.column(x, z);
				if(c < 0 || world.top_y[c] == NO_GROUND)
					continue;
				for(int y = f.origin.y; y < world.top_y[c]; y++)
					f.set(x, y, z, vp::SOLID);
			}
		// The target (a lantern) taken as room: it is beside it a step
		// before, where it acts
		f.set(goal.x, goal.y, goal.z, vp::OPEN);
		f.set(goal.x, goal.y + 1, goal.z, vp::OPEN);
		vp::Rules r;
		r.body_height = MOB_HEIGHT[SKELETON];
		r.step_up = 1;
		r.max_fall = 2;
		r.build_cost = build ? BUILD_COST : 0;
		r.max_expanded = cap;
		const vp::Result res = vp::find(f, from, goal, r);
		if(!res.found || res.path.size() < 2)
			return false;
		m.route.assign(res.path.begin() + 1, res.path.end());
		m.build = !res.blocks.empty();
		if(m.build){
			m.build_at = res.blocks[0];
			const vp::P over(m.build_at.x, m.build_at.y + 1, m.build_at.z);
			auto it = std::find(m.route.begin(), m.route.end(), over);
			if(it == m.route.end())
				return m.route.clear(), false;
			m.route.erase(it + 1, m.route.end());
		}
		log_i(MODULE, "skeldat: a skeleton (%u) finds a way to %d,%d,%d: "
				"%zu steps, %zu bone blocks", key, goal.x, goal.y, goal.z,
				res.path.size() - 1, res.blocks.size());
		return true;
	}

	// A step along m's route; at its block's cell, the block built (the
	// night's, or a try at the lantern) and the route done
	void follow_route(uint32_t key, Mob &m)
	{
		const vp::P n = m.route.front();
		if(m.build && m.route.size() == 1){
			const vp::P &b = m.build_at;
			const uint32_t id = world.id_at(b.x, b.y, b.z);
			const skeldat::NodeDef *def = world.node_of(id);
			if(id == ID_AIR || (def && def->shape == skeldat::LIQUID)){
				world.set_node(b.x, b.y, b.z, world.id_of("skeldat:bone_block"), 0,
						skeldat::bones::MAX);
				night_blocks++;
				m.built = true;
				if(m.seeding && m.quota > 0)
					m.quota--;
				log_i(MODULE, "skeldat: a skeleton (%u) builds a bone block "
						"at %d,%d,%d", key, b.x, b.y, b.z);
			}
			m.route.clear();
			m.search_t = 0;
			return;
		}
		const int mx = (int)std::floor(m.x + 0.5f),
				mz = (int)std::floor(m.z + 0.5f);
		float y = -1e9f;
		if(m.node_id){
			Ground g;
			voxelworld::access(world.server, world.scene, [&](voxelworld::Instance *w){
				g = world.ground(w, (float)n.x, m.y, (float)n.z, MOB_HEIGHT[SKELETON]);
			});
			if(g.found && !g.water)
				y = g.y;
		} else {
			const long c = world.column(n.x, n.z);
			if(c >= 0 && world.top_y[c] != NO_GROUND)
				y = world.top_y[c] + 0.5f;
		}
		// The world changed under it, or a column top that is not the way;
		// or a step into the sun ([SKELDAT_SUN_SHELTER])
		if(std::abs(n.x - mx) > 1 || std::abs(n.z - mz) > 1 ||
				std::fabs(y - (n.y - 0.5f)) > 0.01f || sun_refuses(m, n.x, y, n.z)){
			m.route.clear();
			return;
		}
		m.yaw = std::atan2((float)(n.x - mx), (float)(n.z - mz));
		m.x = (float)n.x, m.z = (float)n.z, m.y = y;
		m.route.erase(m.route.begin());
	}

	// A game hour: the count toward its target, added at night on bone
	// columns, let die in the morning on clean ground
	// The bodiless skeletons within FAR_DRAW of each player, to be drawn
	// ([SKELDAT_FAR_SKELETONS]): "x y z yaw" a line, the place rounded to
	// the voxel and the yaw to a sixteenth of a turn; sent when it differs
	void send_far()
	{
		static const float FAR_DRAW = 160;
		for(auto &pair : players){
			Player &pl = pair.second;
			if(!pl.placed)
				continue;
			std::ostringstream os;
			size_t n = 0;
			for(auto &kv : all){
				const Mob &m = kv.second;
				if(m.kind != SKELETON || m.node_id ||
						std::fabs(m.x - pl.x) > FAR_DRAW ||
						std::fabs(m.z - pl.z) > FAR_DRAW ||
						std::hypot(m.x - pl.x, m.z - pl.z) > FAR_DRAW)
					continue;
				const int yaw = ((int)std::lround(m.yaw / (2 * M_PI) * 16) %
						16 + 16) % 16;
				os<<(int)std::floor(m.x + 0.5f)<<" "<<m.y<<" "
						<<(int)std::floor(m.z + 0.5f)<<" "<<yaw<<"\n";
				n++;
			}
			const ss_ s = os.str();
			if(s == pl.far_sent)
				continue;
			pl.far_sent = s;
			network::send(world.server, pair.first, "skeldat:far", s);
			if(far_report)
				log_i(MODULE, "skeldat: %zu far skeletons to %s", n,
						cs(pl.name));
		}
	}

	// The skeletons' count and its target by the flooded share f
	size_t skeleton_target(size_t &n, double &f)
	{
		n = 0;
		for(auto &kv : all)
			n += kv.second.kind == SKELETON;
		int64_t flooded = 0, land = 0;
		for(int c : growth.flooded)
			flooded += c;
		for(int c : growth.land)
			land += c;
		const double columns = (double)world.footprints() *
				skeldat::bones::SECTION * skeldat::bones::SECTION;
		// Of the land ([SKELDAT_OWN_MAPGEN]: a sea's water is never
		// flooded); the count by the world's size
		f = land > 0 ? (double)flooded / land : 0;
		return (size_t)std::lround((SKELETONS_MIN +
				(SKELETONS_MAX - SKELETONS_MIN) * f) * columns / (1024. * 1024.));
	}

	// A world's skeletons there from the start ([SKELDAT_START_SKELETONS]):
	// once a world is in, the first time (a new world, or one made before
	// this), the count up to its target at once, on bone columns (anywhere
	// in a world with none); no player is placed yet, so none is too near
	void populate()
	{
		std::string v;
		if(!store || store->get("populated", v))
			return;
		size_t n;
		double f;
		const size_t target = skeleton_target(n, f);
		const bool any = std::any_of(growth.flooded.begin(), growth.flooded.end(),
				[](int c){ return c > 0; });
		size_t added = 0;
		const size_t want = target > n ? target - n : 0;
		for(size_t t = 0; t < 8 * want && added < want; t++)
			added += add_skeleton(any);
		store->set("populated", "1");
		log_i(MODULE, "skeldat: populated: %zu skeletons added, %zu in all, "
				"the target %zu", added, n + added, target);
	}

	void step_population()
	{
		size_t n;
		double f;
		const size_t target = skeleton_target(n, f);
		const size_t k = 1 + (n > target ? n - target : target - n) / 10;
		size_t added = 0, died = 0;
		const bool night = world.day < 0.25 || world.day >= 0.75,
				morning = world.day >= 0.25 && world.day < 0.4;
		{
			if(night && n < target){
				const size_t want = std::min(k, target - n);
				// On bones; anywhere in a world with none
				const bool any = std::any_of(growth.flooded.begin(),
						growth.flooded.end(), [](int c){ return c > 0; });
				for(size_t t = 0; t < 8 * want && added < want; t++)
					added += add_skeleton(any);
			}
			if(morning && n > target){
				const size_t want = std::min(k, n - target);
				for(auto it = all.begin(); it != all.end() &&
						died < want;){
					const Mob &m = it->second;
					const long c = world.column((int)std::floor(m.x + 0.5f),
							(int)std::floor(m.z + 0.5f));
					// By the sun's rule from its voxels; where they are not
					// loaded, the column top's bones.
					// simplified: unloaded, a bone block or skull beside it
					// does not count
					int safe = -1;
					if(m.kind == SKELETON && !m.node_id && c >= 0)
						voxelworld::access(world.server, world.scene,
								[&](voxelworld::Instance *w){
							safe = world.sun_safe(w, m.x, m.y, m.z);
						});
					if(safe < 0 && c >= 0)
						safe = world.top_b[c] >= skeldat::bones::FLOOD;
					if(m.kind != SKELETON || m.node_id || c < 0 || safe || m.boat){
						++it;
						continue;
					}
					if(store)
						store->remove("mob/"+itos(it->first));
					leave_lantern(it->second);
					it = all.erase(it);
					died++;
				}
			}
		}
		log_i(MODULE, "skeldat: %zu skeletons, the target %zu (%.3f of the land's "
				"columns flooded); %zu added, %zu let die", n + added - died,
				target, f, added, died);
	}

	// Two points a tick on each flying arrow, the middle and the end: at
	// 18 voxels a second it goes 0.6 a tick, so a point every 0.3
	void step_arrows(float dt)
	{
		pick_stuck();
		if(arrows.empty())
			return;
		sv_<char> solid;
		voxelworld::access(world.server, world.scene, [&](voxelworld::Instance *w){
			for(Arrow &a : arrows){
				if(a.stuck)
					continue;
				for(float f : {0.5f, 1.0f}){
					const float vy = a.vy - ARROW_GRAVITY * dt;
					solid.push_back(world.walkable(w,
							(int)std::floor(a.x + a.vx * dt * f + 0.5f),
							(int)std::floor(a.y + vy * dt * f + 0.5f),
							(int)std::floor(a.z + a.vz * dt * f + 0.5f)));
				}
			}
		});
		size_t j = 0;
		sv_<Arrow> kept;
		// by: the shooting mob's kind, -1 a player
		struct Hit { uint32_t key; int dmg; size_t peer; float x, z; bool head;
			int by; };
		sv_<Hit> hits;
		for(Arrow &a : arrows){
			a.age += dt;
			bool gone = !a.stuck && a.age > 8;
			// [SKELDAT_BOW] Stuck: a living player near takes it if it fits;
			// after ARROW_STUCK it is a voxel, or gone where there is no air
			if(a.stuck && (picked(a.x, a.y, a.z) || a.age > ARROW_STUCK)){
				if(a.age > ARROW_STUCK)
					stick_voxel(a);
				remove_node(a.node_id);
				continue;
			}
			const bool was_stuck = a.stuck;
			const size_t base = j;
			if(!a.stuck){
				j += 2;
				a.vy -= ARROW_GRAVITY * dt;
			}
			for(int k = 0; !gone && !a.stuck && k < 2; k++){
				const float f = k ? 1.0f : 0.5f;
				const float x = a.x + a.vx * dt * f, y = a.y + a.vy * dt * f,
						z = a.z + a.vz * dt * f;
				// A player's hits the mobs, as a hit by the player; a
				// skeleton's the other skeleton kind's ([SKELDAT_CAVE_SKELETON])
				{
					for(auto &kv : all){
						const Mob &m = kv.second;
						if(!a.by_player && (m.kind == BOAR || m.kind == a.shooter))
							continue;
						const bool sk = m.kind != BOAR;
						const float mx = sk ? m.bx : m.x, my = sk ? m.by : m.y,
								mz = sk ? m.bz : m.z;
						if(m.node_id && std::hypot(mx - x, mz - z) < 0.5f &&
								y > my - 0.1f && y < my + MOB_HEIGHT[m.kind] + 0.1f){
							const float v = std::sqrt(a.vx * a.vx + a.vy * a.vy +
									a.vz * a.vz);
							// [SKELDAT_HEADSHOT] A skeleton's head, its top half
							// voxel, the arrow's way passing within 0.3 of the
							// middle (the head's 0.25 and the arrow's slack; the
							// point tested is anywhere in the body's 0.5), kills
							// it: its hp the damage
							// simplified: a column over the body's middle, not the
							// turned head's box
							const float vh = std::hypot(a.vx, a.vz);
							const float across = vh > 0 ? std::fabs((mx - x) * a.vz -
									(mz - z) * a.vx) / vh : std::hypot(mx - x, mz - z);
							// A player's: a skeleton's at the other kind's head
							// would end their fight at once
							const bool head = a.by_player && sk && y >= my + 1.5f &&
									across < 0.3f;
							hits.push_back({kv.first, head ? std::max(1, m.hp) :
									std::max(1, (int)std::lround(BOW_DAMAGE * v)),
									a.by_player ? a.peer : NOBODY, x, z, head,
									a.by_player ? -1 : (int)a.shooter});
							if(a.by_player){
								host.sound("arrow_hit", x, y, z, a.peer);
								host.sound_near(a.peer, "arrow_hit", x, y, z);
							} else {
								host.sound("arrow_hit", x, y, z);
							}
							gone = true;
							break;
						}
					}
				}
				for(auto &pair : players){
					Player &pl = pair.second;
					if(!gone && !a.by_player && pl.placed && pl.hp > 0 &&
							std::hypot(pl.x - x, pl.z - z) < 0.45f &&
							y > pl.y - 0.1f && y < pl.y + 1.85f){
						host.hurt(pair.first, pl, 2 + world.rand() % 3,
								"is hit by an arrow");
						host.sound("arrow_hit", x, y, z);
						gone = true;
						break;
					}
				}
				if(gone)
					break;
				if(solid[base + k]){
					a.stuck = true;
					a.age = 0;
					a.sx = (int)std::floor(x + 0.5f), a.sy = (int)std::floor(y + 0.5f),
							a.sz = (int)std::floor(z + 0.5f);
					a.fx = (int)std::floor(a.x + 0.5f), a.fy = (int)std::floor(a.y + 0.5f),
							a.fz = (int)std::floor(a.z + 0.5f);
					log_i(MODULE, "skeldat: an arrow sticks at %.1f,%.1f,%.1f",
							a.x, a.y, a.z);
					if(a.by_player){
						host.sound("arrow_land", a.x, a.y, a.z, a.peer);
						host.sound_near(a.peer, "arrow_land", a.x, a.y, a.z);
					} else
						host.sound("arrow_land", a.x, a.y, a.z);
				} else
					a.x = x, a.y = y, a.z = z;
			}
			if(gone){
				remove_node(a.node_id);
				continue;
			}
			if(!was_stuck){
				main_context::access(world.server, world.scene, [&](Urho3D::Scene *scene){
					if(Urho3D::Node *n = scene->GetNode(a.node_id)){
						n->SetPosition(Urho3D::Vector3(a.x, a.y, a.z));
						if(!a.stuck){
							Urho3D::Quaternion r;
							r.FromLookRotation(Urho3D::Vector3(a.vx, a.vy, a.vz));
							n->SetRotation(r);
						}
					}
				});
			}
			kept.push_back(a);
		}
		arrows.swap(kept);
		for(const Hit &h : hits){
			if(!all.count(h.key))
				continue;
			auto pl = players.find(h.peer);
			const ss_ by = h.by >= 0 ? ss_("a ")+MOB_KIND[h.by] :
					pl != players.end() ? pl->second.name : ss_("?");
			if(h.head)
				log_i(MODULE, "skeldat: %s's headshot kills the %s (%u)",
						cs(by), MOB_KIND[all[h.key].kind], h.key);
			else
				log_i(MODULE, "skeldat: an arrow from %s hits the %s (%u) for %d",
						cs(by), MOB_KIND[all[h.key].kind], h.key, h.dmg);
			// A skeleton's kill leaves the drops on the ground, as a player's
			damage(h.key, h.dmg, h.peer, h.x, h.z, h.by >= 0);
		}
	}

	// [SKELDAT_BOW] A living player within ARROW_REACH of (x, y, z) with
	// room takes an arrow: true when one did
	bool picked(float x, float y, float z)
	{
		for(auto &pair : players){
			Player &pl = pair.second;
			if(!pl.placed || pl.hp <= 0 || std::hypot(pl.x - x, pl.z - z) >=
					ARROW_REACH || y < pl.y - 1 || y > pl.y + 2.5f)
				continue;
			if(!world.game.add(pl.main, Stack("skeldat:arrow")).empty())
				continue;
			host.send_inventory(pair.first, pl);
			host.sound("pickup", x, y, z, pair.first);
			host.sound_own(pair.first, "pickup");
			log_i(MODULE, "skeldat: %s picks up an arrow at %.1f,%.1f,%.1f",
					cs(pl.name), x, y, z);
			return true;
		}
		return false;
	}

	// A stuck arrow kept for good: a stuck_arrow voxel where it sticks
	// out, turned to the face it went into (wallmounted's param2 toward
	// that voxel); none where that is not air
	void stick_voxel(const Arrow &a)
	{
		int d[3] = {a.sx - a.fx, a.sy - a.fy, a.sz - a.fz};
		int axis = 0;
		for(int i = 1; i < 3; i++)
			if(std::abs(d[i]) > std::abs(d[axis]))
				axis = i;
		if(d[axis] == 0 || world.id_at(a.fx, a.fy, a.fz) != ID_AIR)
			return;
		// 0 +y, 1 -y, 2 +x, 3 -x, 4 +z, 5 -z
		const uint32_t param = axis == 1 ? (d[1] > 0 ? 0 : 1) :
				axis == 0 ? (d[0] > 0 ? 2 : 3) : (d[2] > 0 ? 4 : 5);
		world.set_node(a.fx, a.fy, a.fz, world.stuck_id, param);
		log_i(MODULE, "skeldat: a stuck arrow kept at %d,%d,%d, facing %u",
				a.fx, a.fy, a.fz, param);
	}

	// The stuck_arrow voxels near a living player, picked up as arrows
	void pick_stuck()
	{
		if(stuck.empty() || players.empty())
			return;
		sv_<ss_> taken;
		for(const ss_ &k : stuck){
			int x, y, z;
			if(Furnaces::parse_pos(k, x, y, z) && picked((float)x, (float)y, (float)z))
				taken.push_back(k);
		}
		for(const ss_ &k : taken){
			int x, y, z;
			Furnaces::parse_pos(k, x, y, z);
			world.set_node(x, y, z, ID_AIR);
		}
	}

	// A skeleton takes the lantern at `at`: out of the world, put out, its
	// coal with it
	void take_lantern(uint32_t key, Mob &m, const pv::Vector3DInt32 &at)
	{
		if(m.carry_coal >= 0)
			return;
		const int coal = furnaces.take_lantern(at);
		if(coal < 0)
			return;
		m.carry_coal = coal;
		log_i(MODULE, "skeldat: a skeleton (%u) takes the lantern at %s, %d "
				"coal in it", key, cs(pos_key(at.getX(), at.getY(), at.getZ())),
				m.carry_coal);
	}

	// A skeleton dead with no one to take what it had: its lantern left
	// where it died, unlit, with its coal
	void leave_lantern(Mob &m)
	{
		if(m.carry_coal < 0)
			return;
		furnaces.leave_lantern(m.x, m.y, m.z, m.carry_coal);
		m.carry_coal = -1;
	}
};
// vim: set noet ts=4 sw=4:



