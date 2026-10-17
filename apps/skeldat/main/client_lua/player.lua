-- Buildat: apps/skeldat/main/client_lua/player.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- Copied from builtin/luanti/client_lua/player.lua ([SKELDAT]: the
-- movement copied into the app), itself a copy of
-- extensions/luanti_client/player.lua, where its checks are. Nothing in it
-- knows Luanti's protocol or Urho3D; edit it there and copy it here
-- rather than letting the copies drift.
-- The board ([SKELDAT_SKATEBOARD], below the walk) is this copy's own.
--
-- coordinate stops the player, which is what makes it checkable without
-- either of them (see test.lua).
--
-- Collisions are resolved one axis at a time, and only against the nodes the
-- box moves into. Resolving axis by axis is what makes sliding along a wall
-- work; looking only at the nodes ahead is what keeps a player who is already
-- inside a node -- the server put them there, or something was built on them
-- -- able to move out of it.

local M = {}

M.RADIUS = 0.3
M.HEIGHT = 1.75
-- Luanti's own step height: a player walks onto anything this much higher
-- without jumping, which is what makes a stair or a slab walkable. In the
-- air it is 0.2 (LocalPlayer::move: touching_ground ? stepheight : 0.2*BS)
M.STEP_HEIGHT = 0.6
M.AIR_STEP_HEIGHT = 0.2
-- How high autojump looks for a way through (LocalPlayer::handleAutojump)
M.AUTOJUMP_HEIGHT = 1.1
-- ClientEnvironment::step() cuts a frame into steps of at most this long,
-- and of at most STEP_MAX_MOVE nodes of travel, so that what a jump does
-- is the same at any frame rate ([PLAYER_PHYSICS]); a frame over
-- DTIME_LIMIT loses the rest, as Luanti's does
M.STEP_MAX_S = 0.01
M.STEP_MAX_MOVE = 0.1
M.DTIME_LIMIT = 2.5
-- How far past the edge of the node last stood on a sneaking player's
-- centre may go: the box's half width times 0.49, "to keep the center just
-- barely on the node" (LocalPlayer::move)
M.SNEAK_MAX = M.RADIUS * 0.49
-- Where the eyes are above the feet, which is what the camera follows
M.EYE_HEIGHT = 1.625
-- Luanti's movement defaults, which is what TOCLIENT_MOVEMENT carries and
-- what a game changes when it wants a different feel. Nodes a second, and
-- nodes a second squared.
M.DEFAULT_MOVEMENT = {
	acceleration_default = 3,
	acceleration_air = 2,
	acceleration_fast = 10,
	speed_walk = 4,
	speed_crouch = 1.35,
	speed_fast = 20,
	speed_climb = 3,
	speed_jump = 6.5,
	liquid_fluidity = 1,
	liquid_fluidity_smooth = 0.5,
	liquid_sink = 10,
	gravity = 9.81,
}

-- [SKELDAT_SKATEBOARD] The board, skeldat's own (not in the copies this
-- one came from): steps of up to BOARD_STEP up or down ridden as a slope,
-- nothing slowing it but a climb and the brake, under BOARD_STOP walked
-- off. Speeds in voxels a second, the brake in voxels a second squared,
-- the turn in radians a second at a standstill (it falls with the speed).
M.BOARD_STEP = 2
M.BOARD_BRAKE = 24
M.BOARD_STOP = 0.5
M.BOARD_JUMP = 2 -- times speed_jump
M.BOARD_TURN = 3
-- Half the board's length: where its ends sample the ground
M.BOARD_HALF = 0.6
-- [SKELDAT_BOARD_PRONE] Lying flat on the board (Shift): the box this
-- high, under a voxel with the board under it, and the eye this far over
-- the feet, eased there and back in PRONE_EASE seconds
M.PRONE_HEIGHT = 0.8
M.PRONE_EYE = 0.5
M.PRONE_EASE = 0.25
-- The board's frame is cut finer by travel than walking's, coarser by time
M.BOARD_STEP_S = 0.02
M.BOARD_STEP_MOVE = 0.25

-- What a voxel that is a whole cube is made of, in its own coordinates: the
-- shorthand solid() returns true for
local CUBE = {{-0.5, -0.5, -0.5, 0.5, 0.5, 0.5}}

-- The box as an offset from the position, per axis (1 = x, 2 = y, 3 = z)
local OFF_LO = {-M.RADIUS, 0, -M.RADIUS}
local OFF_HI = {M.RADIUS, M.HEIGHT, M.RADIUS}

-- What a player with nothing done to them moves by; see self.override
local EMPTY_OVERRIDE = {}

-- How much of a node's move_resistance counts, which is Luanti's own
-- constant: resistance 0 still leaves seven tenths of the drag, and each
-- point adds three tenths more. See ClientEnvironment::step().
local RESISTANCE_FACTOR = 0.3

-- Acceleration on the wire is in voxels/s² only after another factor of BS;
-- see where it is used below.
local BS_ACCEL = 10

-- A node at integer coordinate i covers [i - 0.5, i + 0.5]. These are the
-- first and last node a span reaches into; touching is not overlapping, which
-- is what lets the player stand exactly on a surface.
local function cell_lo(v)
	return math.floor(v + 0.5)
end

local function cell_hi(v)
	return math.ceil(v - 0.5)
end

-- Moves the box along one axis until something stops it. p is {x, y, z} and
-- is changed in place; returns true if something stopped it.
--
-- solid(x, y, z) says what is at a node position: false for nothing, true for
-- the whole voxel, or the boxes it is made of, each {x0, y0, z0, x1, y1, z1}
-- in the voxel's own -0.5...0.5 coordinates. A box the player is already
-- inside of does not stop them, which is what lets somebody the server put
-- inside a wall walk out of it. height: the box's, M.HEIGHT if nil (lying
-- flat on the board is lower, [SKELDAT_BOARD_PRONE]).
local function move_axis(p, axis, d, solid, height)
	if d == 0 then
		return false
	end
	-- The two axes the box does not move along, as the span it covers there
	local a1, a2
	for a = 1, 3 do
		if a ~= axis then
			if not a1 then a1 = a else a2 = a end
		end
	end
	local OFF_HI = height and {M.RADIUS, height, M.RADIUS} or OFF_HI
	local lo1, hi1 = p[a1] + OFF_LO[a1], p[a1] + OFF_HI[a1]
	local lo2, hi2 = p[a2] + OFF_LO[a2], p[a2] + OFF_HI[a2]
	local u0, u1 = cell_lo(lo1), cell_hi(hi1)
	local v0, v1 = cell_lo(lo2), cell_hi(hi2)

	-- The cells the box moves through, nearest first. It starts at the cell
	-- the moving edge is already in rather than the next one: a voxel made
	-- of boxes can have one below the player's feet in the same cell as the
	-- feet -- standing on a slab is exactly that -- and a box the player is
	-- already past is skipped below anyway.
	local from, to, step
	if d > 0 then
		from = cell_hi(p[axis] + OFF_HI[axis])
		to = cell_hi(p[axis] + d + OFF_HI[axis])
		step = 1
	else
		from = cell_lo(p[axis] + OFF_LO[axis])
		to = cell_lo(p[axis] + d + OFF_LO[axis])
		step = -1
	end

	-- Touching is not overlapping: a player standing exactly on a surface is
	-- not inside it
	local E = 1e-9
	local q = {0, 0, 0}
	for c = from, to, step do
		q[axis] = c
		local stop = nil
		for u = u0, u1 do
			q[a1] = u
			for v = v0, v1 do
				q[a2] = v
				local what = solid(q[1], q[2], q[3])
				if what then
					local boxes = what == true and CUBE or what
					for _, b in ipairs(boxes) do
						-- The box where it is in the world
						local b_lo1 = q[a1] + b[a1]
						local b_hi1 = q[a1] + b[a1 + 3]
						local b_lo2 = q[a2] + b[a2]
						local b_hi2 = q[a2] + b[a2 + 3]
						if b_hi1 > lo1 + E and b_lo1 < hi1 - E and
								b_hi2 > lo2 + E and b_lo2 < hi2 - E then
							local at
							if d > 0 then
								at = q[axis] + b[axis] - OFF_HI[axis]
								if at >= p[axis] - E and
										(not stop or at < stop) then
									stop = at
								end
							else
								at = q[axis] + b[axis + 3] - OFF_LO[axis]
								if at <= p[axis] + E and
										(not stop or at > stop) then
									stop = at
								end
							end
						end
					end
				end
			end
		end
		if stop and ((d > 0 and stop < p[axis] + d) or
				(d < 0 and stop > p[axis] + d)) then
			p[axis] = stop
			return true
		end
	end
	p[axis] = p[axis] + d
	return false
end

M.move_axis = move_axis

-- One horizontal move, stepping up onto what is low enough to step onto: the
-- move is tried again from a step up, and what the player then stands on is
-- found by settling back down. Only from the ground, so a jump does not
-- climb a wall.
local function move_horizontal(p, axis, d, solid, step_height, height)
	local direct = {p[1], p[2], p[3]}
	local hit = move_axis(direct, axis, d, solid, height)
	local function take(q)
		p[1], p[2], p[3] = q[1], q[2], q[3]
	end
	if not hit or not step_height or step_height <= 0 then
		take(direct)
		return hit
	end
	-- No room to rise, or still blocked up there: the plain move it is
	local up = {p[1], p[2], p[3]}
	if move_axis(up, 2, step_height, solid, height) then
		take(direct)
		return true
	end
	if move_axis(up, axis, d, solid, height) then
		take(direct)
		return true
	end
	move_axis(up, 2, -step_height, solid, height)
	take(up)
	return false
end

M.move_horizontal = move_horizontal

local function never_solid()
	return false
end

-- Moves v towards target by at most max
local function approach(v, target, max)
	if target > v then
		return math.min(target, v + max)
	end
	return math.max(target, v - max)
end

-- new(is_solid, is_liquid)
--
-- is_solid(x, y, z) says what stops the player at those integer coordinates:
-- false for nothing, true for the whole voxel, or the boxes it is made of.
-- It is asked about nodes that may not have arrived, and should say true for
-- those: standing still in a world that has not loaded is better than falling
-- through it.
--
-- is_liquid(x, y, z) says whether it is something to swim in. Optional.
--
-- groups_at(x, y, z) says what standing on the node does: a table (or
-- anything indexable) with bouncy, slippery, disable_jump and
-- disable_descend, Luanti's groups of those names, or nil. Optional.
local function copy_movement()
	local t = {}
	for k, v in pairs(M.DEFAULT_MOVEMENT) do
		t[k] = v
	end
	return t
end

function M.new(is_solid, is_liquid, is_climbable, resistance_at, groups_at)
	local self = {
		x = 0, y = 0, z = 0,
		vx = 0, vy = 0, vz = 0,
		on_ground = false,
		-- [SKELDAT_BOARD_PRONE] Lying flat, and the box's height and the
		-- eye's over the feet that go with it
		prone = false,
		height = M.HEIGHT,
		eye = M.EYE_HEIGHT,
		in_liquid = false,
		in_liquid_stable = false,
		-- Whether a ladder or a vine is holding the player up; see
		-- is_climbable and the vertical part of update()
		climbing = false,
		-- How fast the player was going down when they last hit something,
		-- in nodes a second, or nil. Whoever reads it clears it.
		landed_at = nil,
		-- The node a sneaking player last stood on, which they do not
		-- walk off; see the end of step()
		sneak_node = nil,
		-- Flying and going through walls are off by default and keys toggle
		-- them; a server that does not give the player the fly and noclip
		-- privileges will pull them back with its movement checks
		fly = false,
		noclip = false,
		fast = false,
		-- A copy: the game's constants are written into it when they arrive
		movement = copy_movement(),
		-- What a mod has done to how this player moves: Luanti's
		-- physics_override, which multiplies rather than replaces. Ones
		-- until the server says otherwise; see M.sub_physics in the
		-- module's client half.
		override = {speed = 1, jump = 1, gravity = 1, sneak = 1,
				sneak_glitch = 0},
	}

	-- The server put the player here, so whatever we thought is wrong
	-- A place the server's check believed can have the feet up to a
	-- tenth inside the ground; a box inside a voxel does not stop, so the
	-- player would fall through it: lifted onto a whole voxel whose top is
	-- under half a voxel over the feet
	function self:set_position(x, y, z)
		local fy = cell_lo(y)
		if is_solid(cell_lo(x), fy, cell_lo(z)) == true and fy + 0.5 - y < 0.5 then
			y = fy + 0.5
		end
		self.x, self.y, self.z = x, y, z
		self.vy = 0
		if self.board then
			self.board, self.vx, self.vz = nil, 0, 0
		end
	end

	-- A push the server gave the player, out of TOCLIENT_PLAYER_SPEED: an
	-- explosion, a jump pad, being hit. It is added to the speed once, as
	-- Luanti adds it, and then the physics has it: the vertical part is what
	-- gravity works off, and the horizontal part decays at whatever the
	-- acceleration is, because the keys are a target rather than a force.
	function self:add_velocity(x, y, z)
		self.vx = self.vx + (x or 0)
		self.vy = self.vy + (y or 0)
		self.vz = self.vz + (z or 0)
	end

	-- One step of the player's own physics. wish is what the keys say:
	--   x, z    the direction to walk in, in world coordinates, any length
	--   speed   optional, 0..1 of the speed: a touchscreen's analog stick
	--   jump    up, and out of the water
	--   sneak   down when flying, slower on the ground
	--   fast    the fast speed and the fast acceleration
	-- Returns the position after the step.
	--
	-- The shape is LocalPlayer::applyControl() and move() with
	-- ClientEnvironment::step() around them, one feature at a time; the
	-- table of what matches and what does not is [PLAYER_PHYSICS] in
	-- doc/plan/luanti_module_plan.md.
	--
	-- simplified: sneak_glitch (the sneak ladder), pitch move and object
	-- collisions are not here.
	local function step(dtime, wish)
		local m = self.movement
		-- **Autojump** (LocalPlayer::handleAutojump; on by default in
		-- Luanti's Android client): self.autojump says it is on, and a jump
		-- it chose is held for autojump_t more seconds. See the end of the
		-- horizontal move.
		if (self.autojump_t or 0) > 0 then
			self.autojump_t = self.autojump_t - dtime
			wish.jump = true
		end
		-- Going through walls is the collision test answering no to
		-- everything, which is also how a player who ended up inside
		-- something gets out
		-- Noclip acts only while flying, as official's does ([FLY_MODES]);
		-- fly_active and noclip_active are the modes the game lets act
		-- (its privileges), nil when the game does not say
		local fly = self.fly
		if self.fly_active ~= nil then
			fly = self.fly_active
		end
		local noclip = self.noclip and fly
		if self.noclip_active ~= nil then
			noclip = self.noclip_active and fly
		end
		local stops = noclip and never_solid or is_solid

		local nx = math.floor(self.x + 0.5)
		local nz = math.floor(self.z + 0.5)
		-- In a liquid: read half a node up when out of it and a tenth of a
		-- node up when in it, so that the surface does not flicker the
		-- state (LocalPlayer::move, "the oscillating value")
		local ly = self.y + (self.in_liquid and 0.1 or 0.5)
		local lny = math.floor(ly + 0.5)
		self.in_liquid = is_liquid ~= nil and is_liquid(nx, lny, nz) or false
		-- And the stable one, the node at the feet: what the sneak, the
		-- crouch speed and the slip read, so that a body standing in
		-- shallow water descends by sneak and walks at the walk
		self.in_liquid_stable = is_liquid ~= nil and
				is_liquid(nx, math.floor(self.y + 0.5), nz) or false
		local wet = self.in_liquid or self.in_liquid_stable
		-- A ladder is climbed from the node half a node above the feet or
		-- the one a fifth below them, which is how a player on the bottom
		-- rung holds on and how the top of one is left
		self.climbing = is_climbable ~= nil and not fly and
				not noclip and
				(is_climbable(nx, math.floor(self.y + 0.5 + 0.5), nz) or
				is_climbable(nx, math.floor(self.y - 0.2 + 0.5), nz))
		-- How much what they are standing in holds them back, read from
		-- the same node the liquid is
		local resistance = (resistance_at ~= nil and not noclip) and
				resistance_at(nx, lny, nz) or 0
		-- What the node stood on and the one the feet are in do to the
		-- player (LocalPlayer::move, "the standing node"): either can
		-- refuse a jump or a descent, the one stood on can be slippery
		-- or bouncy
		local stand_y = math.floor(self.y + 0.4)
		local stood = groups_at ~= nil and groups_at(nx, stand_y, nz) or nil
		local feet = groups_at ~= nil and groups_at(nx, stand_y + 1, nz) or nil
		local no_jump = (stood ~= nil and stood.disable_jump) or
				(feet ~= nil and feet.disable_jump) or false
		local no_descend = (stood ~= nil and stood.disable_descend) or
				(feet ~= nil and feet.disable_descend) or false
		local bouncy = stood ~= nil and (stood.bouncy or 0) or 0
		local slippery = stood ~= nil and (stood.slippery or 0) or 0

		-- What a mod has multiplied this player's movement by, which is
		-- ones unless the server has said otherwise
		local ov = self.override or EMPTY_OVERRIDE
		local ov_speed = ov.speed or 1
		local free_move = fly
		-- Horizontal: accelerate towards what the keys ask for. Each
		-- constant has a multiplier of its own in the override besides
		-- the one over all of them.
		local speed = m.speed_walk * (ov.speed_walk or 1)
		if self.prone then
			-- Crawling out of where it lay flat
			speed = m.speed_crouch * (ov.speed_crouch or 1)
		elseif wish.fast then
			speed = m.speed_fast * (ov.speed_fast or 1)
		elseif wish.sneak and not free_move and not wet and
				(ov.sneak or 1) ~= 0 then
			speed = m.speed_crouch * (ov.speed_crouch or 1)
		end
		speed = speed * ov_speed
		local len = math.sqrt(wish.x * wish.x + wish.z * wish.z)
		local target_x, target_z = 0, 0
		if len > 0 then
			local h = speed * math.min(1, wish.speed or 1)
			target_x = wish.x / len * h
			target_z = wish.z / len * h
		end
		-- Which acceleration, as applyControl() picks it: the air's when
		-- off the ground with nothing holding the player (or at the
		-- moment of a jump), the fast one under the fast key, the default
		-- otherwise -- on the ground, in a liquid, on a ladder, flying
		local in_air = not self.on_ground and not free_move and
				not self.climbing and not self.in_liquid
		-- A bouncy node is jumped from between bounces too
		local can_jump = (self.on_ground or bouncy > 0) and not self.climbing and
				not free_move and not no_jump
		local accel_h, accel_v
		local a_fast = m.acceleration_fast * (ov.acceleration_fast or 1)
		local a_air = m.acceleration_air * (ov.acceleration_air or 1)
		local a_default = m.acceleration_default *
				(ov.acceleration_default or 1)
		if in_air or (can_jump and wish.jump) then
			accel_h = wish.fast and a_fast or a_air
			accel_v = 0
		elseif wish.fast then
			accel_h, accel_v = a_fast, a_fast
		else
			accel_h, accel_v = a_default, a_default
		end
		-- Luanti multiplies the acceleration it sent by BS (10) when it
		-- receives TOCLIENT_MOVEMENT and then again in applyControl(),
		-- while speeds get BS only once. In voxel units that leaves the
		-- effective acceleration ten times the wire value.
		local max_h = accel_h * BS_ACCEL * dtime * ov_speed
		-- Ice: the horizontal acceleration, towards a key and towards a
		-- stop alike, is a fraction 1/(slippery+1), twice as slippery
		-- with no key held (LocalPlayer::getSlipFactor)
		if slippery >= 1 and not free_move and not wet then
			if len == 0 then
				slippery = slippery * 2
			end
			max_h = max_h * math.max(0.001, 1 / (slippery + 1))
		end
		local max_v = accel_v * BS_ACCEL * dtime * ov_speed
		-- The horizontal increment is one vector, not one per axis
		local dx, dz = target_x - self.vx, target_z - self.vz
		local dlen = math.sqrt(dx * dx + dz * dz)
		if dlen > max_h and dlen > 0 then
			dx, dz = dx / dlen * max_h, dz / dlen * max_h
		end
		self.vx = self.vx + dx
		self.vz = self.vz + dz

		-- Vertical: what the keys want, reached at the vertical
		-- acceleration, and then what pulls
		local target_v = nil
		local swimming = false
		if free_move then
			target_v = 0
			if wish.jump and not wish.sneak then
				target_v = speed
			elseif wish.sneak and not wish.jump and not no_descend then
				target_v = -speed
			end
		elseif self.climbing then
			target_v = 0
			local climb = m.speed_climb * (ov.speed_climb or 1) * ov_speed
			if wish.jump and not wish.sneak and not no_jump then
				target_v = climb
			elseif wish.sneak and not wish.jump and not no_descend then
				target_v = -climb
			end
			if wish.fast then
				target_v = target_v > 0 and speed or
						(target_v < 0 and -speed or 0)
			end
		elseif self.in_liquid then
			-- No key is a target of nought at the default acceleration,
			-- against the pull below; that tug of war is what makes an
			-- idle player in water sink slowly rather than fall
			target_v = 0
			if wish.jump and not wish.sneak and not no_jump then
				target_v, swimming = speed, true
			elseif wish.sneak and not wish.jump and not no_descend then
				target_v, swimming = -speed, true
			end
		elseif self.in_liquid_stable and wish.sneak and not wish.jump and
				not no_descend then
			-- Feet in it, the read above it out: the sneak still descends
			target_v, swimming = -speed, true
		end
		if target_v ~= nil then
			self.vy = approach(self.vy, target_v, max_v)
		end
		if can_jump and wish.jump and self.vy >= -0.5 then
			-- The jump is the speed set outright, from the ground and
			-- also from a fall slower than half a node a second
			self.vy = m.speed_jump * (ov.jump or 1)
		end
		-- Sneaking on the ground keeps the player on the node last stood
		-- on (LocalPlayer::move, "keep on top of last walked node"): the
		-- centre may go SNEAK_MAX past its edge and no further
		local could_sneak = wish.sneak and not free_move and
				not self.in_liquid and not self.climbing and
				(ov.sneak or 1) ~= 0
		-- What pulls: Luanti's gravity has a factor two in it ("HACK the
		-- factor 2 for gravity is arbitrary" in ClientEnvironment::step,
		-- there since 2011), and in a liquid the pull is twice the
		-- sinking value instead, unless swimming with a key
		local pull = 0
		if free_move or self.climbing then
			pull = 0
		elseif self.in_liquid then
			pull = swimming and 0 or 2 * m.liquid_sink * (ov.liquid_sink or 1)
		else
			pull = 2 * m.gravity * (ov.gravity or 1)
		end

		-- What being in something thick does, which is Luanti's own
		-- arithmetic out of ClientEnvironment::step(): a drag along the
		-- direction of travel, scaled by the node's resistance. In a liquid
		-- it is capped at the smooth fluidity, so water pulls a walk down to
		-- its own pace instead of stopping it; out of one -- a game can put
		-- resistance on anything -- it is proportional to the speed, which
		-- is what makes a cobweb a cobweb.
		if resistance > 0 then
			local len = math.sqrt(self.vx * self.vx + self.vy * self.vy +
					self.vz * self.vz)
			if len > 1e-6 then
				local dl
				if self.in_liquid or self.in_liquid_stable then
					-- Luanti keeps both fluidities in BS units (x10) and
					-- the speed too, so the speed's BS cancels and the cap
					-- keeps its own: in nodes, v / fluidity capped at ten
					-- times the smooth one. The other way round, the cap
					-- was a tenth of Luanti's and water barely slowed a walk.
					local fluidity = math.max(0.001, m.liquid_fluidity *
							math.max(1, ov.liquid_fluidity or 1))
					local smooth = math.max(0, m.liquid_fluidity_smooth *
							(ov.liquid_fluidity_smooth or 1))
					dl = math.min(len / fluidity, smooth * 10)
				else
					dl = len
				end
				dl = dl * (resistance * RESISTANCE_FACTOR +
						(1 - RESISTANCE_FACTOR))
				local take = math.min(dl * dtime * 10, len)
				local k = take / len
				self.vx = self.vx - self.vx * k
				self.vy = self.vy - self.vy * k
				self.vz = self.vz - self.vz * k
			end
		end

		-- The move, at the average speed over the step, which is what
		-- collisionMoveSimple() moves by
		local vy0 = self.vy
		self.vy = self.vy - pull * dtime
		local avg_vy = (vy0 + self.vy) / 2

		local p = {self.x, self.y, self.z}
		-- Vertically first, so that whether the player is standing on
		-- something is settled before a step up is considered
		if move_axis(p, 2, avg_vy * dtime, stops, self.height) then
			self.on_ground = avg_vy < 0
			-- A bouncy node throws a fall back up at bouncy/100 of it
			-- (collisionMoveSimple); a bounce too slow to clear the
			-- feet settles instead of buzzing
			-- simplified: the node hit is taken to be the one stood on
			-- before the move, which a fall onto a bouncy node from a
			-- neighbouring one gets wrong for one step
			local bounce = (avg_vy < 0 and bouncy > 0) and
					-vy0 * bouncy / 100 or 0
			-- How hard the landing was, in nodes a second, for whoever
			-- tells the server about it. Left here to be read and cleared:
			-- this module knows nothing about damage, and what a fall costs
			-- is the game's arithmetic and not the physics'.
			-- The hardest since it was last read: the substeps that
			-- follow a landing in the same frame land again at nought
			if avg_vy < 0 and -vy0 > (self.landed_at or 0) then
				self.landed_at = -vy0
			end
			self.vy = 0
			if bounce > 1 then
				self.vy = bounce
				self.on_ground = false
			end
		else
			self.on_ground = false
		end

		-- Then along each horizontal axis on its own, which is what makes a
		-- walk into a wall at an angle slide along it. Anything up to a step
		-- height is walked onto rather than into, so a stair or a slab does
		-- not need a jump; a whole voxel does, which is what Luanti asks for
		-- as well. A fifth of a node in the air, which is what lets a jump
		-- that just misses the top of a node land on it.
		local step_height = self.on_ground and M.STEP_HEIGHT or
				M.AIR_STEP_HEIGHT
		local p0 = {p[1], p[2], p[3]}
		local hit_x = move_horizontal(p, 1, self.vx * dtime, stops,
				step_height, self.height)
		local hit_z = move_horizontal(p, 3, self.vz * dtime, stops,
				step_height, self.height)
		-- Autojump: walking on the ground into something the step does not
		-- take, with room over the head, jumps when the same move from a
		-- jump's height (Luanti's 1.1) would get further
		if self.autojump and self.on_ground and (hit_x or hit_z) and
				not wish.jump and not wish.sneak and not fly and
				((wish.x or 0) ~= 0 or (wish.z or 0) ~= 0) then
			local q = {p0[1], p0[2], p0[3]}
			if not move_axis(q, 2, M.AUTOJUMP_HEIGHT, stops) then
				move_horizontal(q, 1, self.vx * dtime, stops, nil)
				move_horizontal(q, 3, self.vz * dtime, stops, nil)
				local jx, jz = q[1] - p0[1], q[3] - p0[3]
				local rx, rz = p[1] - p0[1], p[3] - p0[3]
				if jx * jx + jz * jz > (rx * rx + rz * rz) * 1.01 then
					self.autojump_t = 0.1
				end
			end
		end
		if hit_x then
			self.vx = 0
		end
		if hit_z then
			self.vz = 0
		end
		-- The ledge: back onto the sneak node's reach, and the speed that
		-- took the player past it is gone
		local sn = self.sneak_node
		if could_sneak and sn then
			local lo, hi = sn.x - 0.5 - M.SNEAK_MAX, sn.x + 0.5 + M.SNEAK_MAX
			local cx = math.max(lo, math.min(hi, p[1]))
			if cx ~= p[1] then
				p[1], self.vx = cx, 0
			end
			lo, hi = sn.z - 0.5 - M.SNEAK_MAX, sn.z + 0.5 + M.SNEAK_MAX
			local cz = math.max(lo, math.min(hi, p[3]))
			if cz ~= p[3] then
				p[3], self.vz = cz, 0
			end
		end
		self.x, self.y, self.z = p[1], p[2], p[3]
		-- The next sneak node: the solid node under the feet, while there
		-- is one. Kept while sneaking off its edge, since that is the
		-- point; dropped when not sneaking or nothing is under the feet.
		if could_sneak and self.on_ground then
			local fx, fz = math.floor(self.x + 0.5), math.floor(self.z + 0.5)
			local fy = math.floor(self.y - 0.001 + 0.5)
			if is_solid(fx, fy, fz) then
				self.sneak_node = {x = fx, y = fy, z = fz}
			end
		elseif not could_sneak then
			self.sneak_node = nil
		end
	end

	--
	-- [SKELDAT_SKATEBOARD] The board. self.board is nil walking, else
	-- {s = the speed along the ground, hx, hz = the heading, k = the
	-- slope along it}; in the air (on_ground false) self.vx, vy and vz
	-- carry it as a walk's do. wish.look_x and look_z are where the camera
	-- looks, which the board turns to; wish.brake is the back key.
	--
	local function flying()
		if self.fly_active ~= nil then
			return self.fly_active
		end
		return self.fly
	end
	local function filled(x, y, z)
		local w = is_solid(x, y, z)
		return w ~= false and w ~= nil
	end
	-- The ground of a column near feet height y: the top of the highest
	-- solid voxel at most BOARD_STEP over or under the feet with two open
	-- over it; "wall" when the body's own cells there are solid and there
	-- is no such top; nil when nothing is that close under. Kept for the
	-- frame, by the feet's cell.
	-- simplified: a voxel made of boxes counts as a whole one
	local tops = {}
	local function column_top(cx, cz, y)
		local f = math.floor(y + 0.5)
		local key = ((cx + 32768) * 65536 + cz + 32768) * 1024 + f + 512
		local t = tops[key]
		if t ~= nil then
			return t or nil
		end
		-- Lying flat, one voxel over the ground is room
		local tall = not self.prone
		for c = f + M.BOARD_STEP - 1, f - M.BOARD_STEP - 1, -1 do
			if filled(cx, c, cz) and not filled(cx, c + 1, cz) and
					not (tall and filled(cx, c + 2, cz)) then
				t = c + 0.5
				break
			end
		end
		if t == nil and (filled(cx, f, cz) or (tall and filled(cx, f + 1, cz))) then
			t = "wall"
		end
		tops[key] = t or false
		return t
	end
	-- The ground's height at (x, z): the four column tops round it, each
	-- at its voxel's centre, mixed by distance, which is what makes a step
	-- a slope. A wall beside counts as the centre column, a drop as
	-- falling away. Also the centre column's own top.
	local function surface(x, z, y)
		local centre = column_top(math.floor(x + 0.5), math.floor(z + 0.5), y)
		local x0, z0 = math.floor(x), math.floor(z)
		local ux, uz = x - x0, z - z0
		local h = 0
		for i = 0, 1 do
			for j = 0, 1 do
				local t = column_top(x0 + i, z0 + j, y)
				if t == "wall" then
					t = type(centre) == "number" and centre or y
				elseif t == nil then
					t = y - M.BOARD_STEP - 1
				end
				h = h + t * (i == 1 and ux or 1 - ux) * (j == 1 and uz or 1 - uz)
			end
		end
		return h, centre
	end
	-- The board's height at (x, z), from its two ends and its middle, and
	-- the slope along it
	local function board_at(x, z, y)
		local b = self.board
		local ex, ez = b.hx * M.BOARD_HALF, b.hz * M.BOARD_HALF
		local front = surface(x + ex, z + ez, y)
		local mid, centre = surface(x, z, y)
		local back = surface(x - ex, z - ez, y)
		return (front + 2 * mid + back) / 4,
				(front - back) / (2 * M.BOARD_HALF), centre
	end
	-- Whether the board's move by d along an axis (1 x, 3 z) is stopped: by
	-- a column it cannot ride onto, or by what is over the ground there,
	-- the box lifted onto the highest ground it covers
	local function stopped(axis, d)
		local p = {self.x, self.y, self.z}
		p[axis] = p[axis] + d
		local top = self.y
		for cx = cell_lo(p[1] - M.RADIUS), cell_hi(p[1] + M.RADIUS) do
			for cz = cell_lo(p[3] - M.RADIUS), cell_hi(p[3] + M.RADIUS) do
				local t = column_top(cx, cz, self.y)
				if t == "wall" then
					return true
				end
				if t and t > top then
					top = t
				end
			end
		end
		return move_axis({self.x, top + 0.01, self.z}, axis, d, is_solid,
				self.height)
	end
	local function leave_board()
		local b = self.board
		if self.on_ground then
			local c = 1 / math.sqrt(1 + b.k * b.k)
			self.vx, self.vz = b.hx * b.s * c, b.hz * b.s * c
		end
		self.board = nil
	end
	-- Toward where the camera looks, at a rate falling with the speed
	local function turn(wish, dt)
		local b = self.board
		local lx, lz = wish.look_x or 0, wish.look_z or 0
		if lx == 0 and lz == 0 then
			return
		end
		local now = math.atan2(b.hx, b.hz)
		local diff = (math.atan2(lx, lz) - now + math.pi) % (2 * math.pi) -
				math.pi
		local max = M.BOARD_TURN / (1 + b.s / 8) * dt
		now = now + math.max(-max, math.min(max, diff))
		b.hx, b.hz = math.sin(now), math.cos(now)
	end

	-- One step on the board. On the ground the move is along the slope and
	-- the speed what the height says, s^2 - 2 g dy, which loses nothing:
	-- after any run it is sqrt(v0^2 + 2 g drop), the server's bound. Where
	-- the ground falls away faster than a body thrown along it, the board
	-- flies; it lands keeping the speed along the ground and losing the
	-- rest.
	local function board_step(dt, wish)
		local b = self.board
		local m = self.movement
		local ov = self.override or EMPTY_OVERRIDE
		local g = 2 * m.gravity * (ov.gravity or 1)
		local fx, fz = math.floor(self.x + 0.5), math.floor(self.z + 0.5)
		local fy = math.floor(self.y + 0.5)
		if flying() or (is_liquid ~= nil and is_liquid(fx, fy, fz)) or
				(is_climbable ~= nil and is_climbable(fx, fy, fz)) then
			leave_board()
			return step(dt, wish)
		end
		if self.on_ground then
			turn(wish, dt)
			if wish.brake then
				b.s = math.max(0, b.s - M.BOARD_BRAKE * dt)
			end
			local c = 1 / math.sqrt(1 + b.k * b.k)
			local vy = b.s * b.k * c
			if wish.jump then
				self.vx, self.vz = b.hx * b.s * c, b.hz * b.s * c
				self.vy = vy + M.BOARD_JUMP * m.speed_jump * (ov.jump or 1)
				self.on_ground = false
				return
			end
			local d = b.s * c * dt
			local dx, dz = b.hx * d, b.hz * d
			local bx, bz = stopped(1, dx), stopped(3, dz)
			-- Head on into a wall: walking, still; along one, sliding
			-- with what of the speed went along it
			if (bx and bz) or (bx and math.abs(b.hx) > 0.9) or
					(bz and math.abs(b.hz) > 0.9) then
				self.board, self.vx, self.vz = nil, 0, 0
				return
			elseif bx then
				b.s, b.hx, b.hz, dx = b.s * math.abs(b.hz), 0,
						b.hz >= 0 and 1 or -1, 0
			elseif bz then
				b.s, b.hx, b.hz, dz = b.s * math.abs(b.hx),
						b.hx >= 0 and 1 or -1, 0, 0
			end
			local nx, nz = self.x + dx, self.z + dz
			local ny, k, centre = board_at(nx, nz, self.y)
			local thrown = self.y + vy * dt - 0.5 * g * dt * dt
			if type(centre) ~= "number" or ny < thrown - 0.02 then
				self.vx, self.vz = b.hx * b.s * c, b.hz * b.s * c
				self.x, self.y, self.z = nx, thrown, nz
				self.vy = vy - g * dt
				self.on_ground = false
				return
			end
			local s2 = b.s * b.s - 2 * g * (ny - self.y)
			self.x, self.y, self.z = nx, ny, nz
			self.vy = 0
			b.k, b.s = k, s2 > 0 and math.sqrt(s2) or 0
			if b.s < M.BOARD_STOP then
				leave_board()
			end
			return
		end
		-- In the air: thrown, stopped by a ceiling and by what the board
		-- would not ride onto; ground it would is a landing below
		local vy0 = self.vy
		self.vy = self.vy - g * dt
		local p = {self.x, self.y, self.z}
		local hit_y = move_axis(p, 2, (vy0 + self.vy) / 2 * dt, is_solid,
				self.height)
		self.y = p[2]
		if stopped(1, self.vx * dt) then
			self.vx = 0
		end
		p[1] = self.x + self.vx * dt
		if stopped(3, self.vz * dt) then
			self.vz = 0
		end
		p[3] = self.z + self.vz * dt
		self.x, self.y, self.z = p[1], p[2], p[3]
		if hit_y and vy0 > 0 then
			self.vy = 0
		end
		local hs = math.sqrt(self.vx * self.vx + self.vz * self.vz)
		if hs > 0.1 then
			b.hx, b.hz = self.vx / hs, self.vz / hs
		end
		if self.vy > 0 then
			return
		end
		local ny, k, centre = board_at(p[1], p[3], p[2])
		local on = type(centre) == "number" and p[2] <= ny
		if not on and not (hit_y and vy0 <= 0) then
			return
		end
		self.on_ground = true
		if type(centre) ~= "number" then
			-- Down on something the board does not ride: walking
			self.board, self.vx, self.vz, self.vy = nil, 0, 0, 0
			return
		end
		local along = (hs + self.vy * k) / math.sqrt(1 + k * k)
		local s2 = along > 0 and along * along - 2 * g * (ny - self.y) or 0
		self.y, self.vy = ny, 0
		b.k, b.s = k, s2 > 0 and math.sqrt(s2) or 0
		if b.s < M.BOARD_STOP then
			leave_board()
		end
	end

	-- Onto the board by itself: walking at the walk's speed or more onto
	-- ground a voxel or more lower two ahead. Not sneaking, which is how a
	-- hill is walked down, nor crawling.
	local function try_board(wish)
		if not self.on_ground or self.in_liquid or self.in_liquid_stable or
				self.climbing or flying() or wish.sneak or self.prone then
			return
		end
		local h = math.sqrt(self.vx * self.vx + self.vz * self.vz)
		if h < self.movement.speed_walk * 0.95 then
			return
		end
		local hx, hz = self.vx / h, self.vz / h
		local function top(n)
			return column_top(math.floor(self.x + hx * n + 0.5),
					math.floor(self.z + hz * n + 0.5), self.y)
		end
		local t0, t1, t2 = top(0), top(1), top(2)
		if type(t0) == "number" and type(t1) == "number" and
				type(t2) == "number" and t1 <= t0 + 1e-3 and
				t0 - t2 >= 1 - 1e-3 then
			self.board = {s = h, hx = hx, hz = hz, k = 0}
		end
	end

	function self:update(dtime, wish)
		if dtime <= 0 then
			return self.x, self.y, self.z
		end
		if dtime > M.DTIME_LIMIT then
			dtime = M.DTIME_LIMIT
		end
		tops = {}
		-- Flat while Shift is held on the board; up again where the
		-- standing box fits, off the board too (crawling out of a hole)
		local prone = self.prone
		if self.board and wish.sneak then
			prone = true
		elseif prone and not move_axis({self.x, self.y, self.z}, 2,
				M.HEIGHT - M.PRONE_HEIGHT, is_solid, M.PRONE_HEIGHT) then
			prone = false
		end
		if prone ~= self.prone then
			self.prone, tops = prone, {}
		end
		self.height = prone and M.PRONE_HEIGHT or M.HEIGHT
		local eye = prone and M.PRONE_EYE or M.EYE_HEIGHT
		local ease = (M.EYE_HEIGHT - M.PRONE_EYE) / M.PRONE_EASE * dtime
		self.eye = self.eye + math.max(-ease, math.min(ease, eye - self.eye))
		-- Cut the way ClientEnvironment::step() cuts: ten milliseconds or
		-- a tenth of a node of travel, whichever is shorter, so a long
		-- frame is several short ones and a jump goes the same height
		-- however choppy the client is
		local speed = math.sqrt(self.vx * self.vx + self.vy * self.vy +
				self.vz * self.vz)
		local max_s, max_move = M.STEP_MAX_S, M.STEP_MAX_MOVE
		if self.board then
			speed = math.max(speed, self.board.s)
			max_s, max_move = M.BOARD_STEP_S, M.BOARD_STEP_MOVE
		end
		local max_step = max_s
		if speed > 0.001 then
			max_step = math.min(max_step, max_move / speed)
		end
		local steps = math.ceil(dtime / max_step)
		local part = dtime / steps
		for _ = 1, steps do
			if self.board then
				board_step(part, wish)
			else
				step(part, wish)
				try_board(wish)
			end
		end
		return self.x, self.y, self.z
	end

	return self
end

-- What a liquid does, which is the part of this that had no caller until
-- 2026-09-15: the launcher built a player with no is_liquid at all, so a
-- swim was a walk through air. Empty space, so nothing to stand on, and one
-- of the two worlds is water.
do
	local nothing_stops = function() return false end
	local all_water = function() return true end

	local dry = M.new(nothing_stops)
	local wet = M.new(nothing_stops, all_water)
	for _ = 1, 100 do
		dry:update(0.1, {x = 0, z = 0})
		wet:update(0.1, {x = 0, z = 0})
	end
	assert(dry.in_liquid == false and wet.in_liquid == true,
			"player: a world of water is not being noticed")
	-- Ten seconds of falling: in air that is a speed no game survives, in
	-- water it is the slow idle sink Luanti's tug of war between the pull
	-- and the acceleration towards nought comes to (well under a node a
	-- second, and no faster at a long frame than at a short one)
	assert(dry.vy < -50, "player: nothing slows a fall through air")
	assert(wet.vy < 0 and wet.vy > -1,
			"player: an idle player in water does not sink slowly, vy = " ..
			wet.vy)
	local wet2 = M.new(nothing_stops, all_water)
	for _ = 1, 1000 do
		wet2:update(0.01, {x = 0, z = 0})
	end
	assert(math.abs(wet2.y - wet.y) < 0.05,
			"player: the sink depends on the frame length: " ..
			wet.y .. " vs " .. wet2.y)
	-- And jumping is how you get out of it, from anywhere rather than only
	-- off the ground
	wet:update(0.1, {x = 0, z = 0, jump = true})
	assert(wet.vy > 0 and not wet.on_ground,
			"player: jumping in water does not lift the player")

	-- And how hard a landing was, which is what a fall costs somebody:
	-- dropped onto a floor from high enough to be going fast
	local ground = function(x, y, z) return y <= 0 end
	local dropped = M.new(ground)
	dropped:set_position(0, 30, 0)
	for _ = 1, 100 do
		dropped:update(0.05, {x = 0, z = 0})
		if dropped.landed_at then
			break
		end
	end
	assert(dropped.landed_at and dropped.landed_at > 14,
			"player: a long fall does not report how hard it landed")
	assert(dropped.on_ground, "player: the fall did not end on the ground")

	-- And what something thick does to a walk: the same push into the same
	-- empty space, through air, through water's own resistance, and through
	-- a node seven times as thick -- which is what makes a cobweb a cobweb,
	-- and out of a liquid Luanti's sum takes the whole speed at that point.
	local thin = M.new(nothing_stops)
	local wettish = M.new(nothing_stops, nil, nil, function() return 1 end)
	local web = M.new(nothing_stops, nil, nil, function() return 7 end)
	for _ = 1, 40 do
		thin:update(0.05, {x = 1, z = 0})
		wettish:update(0.05, {x = 1, z = 0})
		web:update(0.05, {x = 1, z = 0})
	end
	assert(wettish.vx > 0 and wettish.vx < thin.vx * 0.9,
			"player: a node that holds a body back does not slow it")
	assert(web.vx < wettish.vx,
			"player: a thicker node is not thicker")
	-- And water at Luanti's defaults pulls a walk of 4 down to about 3,
	-- where the acceleration (30) meets the drag (10 v)
	local swimmer = M.new(nothing_stops, function() return true end, nil,
			function() return 1 end)
	for _ = 1, 40 do
		swimmer:update(0.05, {x = 1, z = 0})
	end
	assert(swimmer.vx > 2.5 and swimmer.vx < 3.3,
			"player: water does not slow a walk to its pace, vx = " ..
			swimmer.vx)

	-- A ladder holds the player where they are, and jump and sneak move
	-- them along it -- which is the whole of climbing
	local ladder = M.new(nothing_stops, nil, all_water)
	for _ = 1, 20 do
		ladder:update(0.1, {x = 0, z = 0})
	end
	assert(ladder.climbing and math.abs(ladder.vy) < 1e-9,
			"player: a ladder does not hold the player up")
	ladder:update(0.1, {x = 0, z = 0, jump = true})
	assert(ladder.vy > 0, "player: jump does not climb")
	ladder:update(0.1, {x = 0, z = 0, sneak = true})
	assert(ladder.vy < 0, "player: sneak does not climb down")

	-- Sneaking stops at the edge of the ground; walking does not
	local cliff = function(x, y, z) return y <= 0 and x <= 2 end
	local sneaker = M.new(cliff)
	local walker = M.new(cliff)
	sneaker:set_position(1, 0.5, 0)
	walker:set_position(1, 0.5, 0)
	-- Put a tenth into the ground, it stands on it
	local sunk = M.new(function(x, y, z) return y <= 0 end)
	sunk:set_position(0, 0.4, 0)
	for _ = 1, 20 do
		sunk:update(0.05, {x = 0, z = 0})
	end
	assert(math.abs(sunk.y - 0.5) < 1e-6,
			"player: put a tenth into the ground, fell to y = " .. sunk.y)
	for _ = 1, 100 do
		sneaker:update(0.05, {x = 1, z = 0, sneak = true})
		walker:update(0.05, {x = 1, z = 0})
	end
	assert(sneaker.on_ground and sneaker.x <= 2.5 + M.SNEAK_MAX + 1e-6 and
			sneaker.x > 2.4,
			"player: sneaking walked off the edge, x = " .. sneaker.x ..
			" y = " .. sneaker.y)
	assert(walker.y < 0, "player: walking did not fall off the edge")

	-- Autojump walks up a whole node, and needs the room over it: a player
	-- without it stops at the node, and so does one under a ceiling
	local steps = function(x, y, z) return y <= 0 or (y == 1 and x >= 3) end
	local roofed = function(x, y, z)
		return y <= 0 or (y == 1 and x >= 3) or y == 3
	end
	local jumper = M.new(steps)
	local plain = M.new(steps)
	local ducked = M.new(roofed)
	jumper.autojump, ducked.autojump = true, true
	for _, pl in ipairs({jumper, plain, ducked}) do
		pl:set_position(1, 0.5, 0)
	end
	for _ = 1, 60 do
		for _, pl in ipairs({jumper, plain, ducked}) do
			pl:update(0.05, {x = 1, z = 0})
		end
	end
	assert(jumper.x > 3 and jumper.y > 1.4,
			"player: autojump did not walk up the node, x = " .. jumper.x ..
			" y = " .. jumper.y)
	assert(plain.x < 2.7 and plain.y < 1,
			"player: a node was walked up without autojump")
	assert(ducked.x < 2.7, "player: autojump jumped into a ceiling")

	-- And what a mod has multiplied the movement by: no gravity is no
	-- falling at all, and twice the speed is twice as fast once the
	-- acceleration has got there
	local floating = M.new(nothing_stops)
	floating.override = {gravity = 0}
	local slow = M.new(nothing_stops)
	local quick = M.new(nothing_stops)
	quick.override = {speed = 2}
	for _ = 1, 50 do
		floating:update(0.1, {x = 0, z = 0})
		slow:update(0.1, {x = 1, z = 0})
		quick:update(0.1, {x = 1, z = 0})
	end
	assert(math.abs(floating.vy) < 1e-9,
			"player: a gravity override of zero still pulls")
	assert(quick.vx > slow.vx * 1.9,
			"player: the speed override does nothing")
end

-- [SKELDAT_SKATEBOARD] The board, on worlds of columns: top(x) the
-- highest solid voxel of the column at x
do
	local function columns(top)
		return function(x, y) return y <= top(x) end
	end
	local g = 2 * M.DEFAULT_MOVEMENT.gravity
	local function run(pl, wish, seconds, each)
		for _ = 1, seconds * 60 do
			pl:update(1 / 60, wish)
			if each then each(pl) end
		end
	end
	local function board(pl, x, y, s)
		pl:set_position(x, y, 0)
		pl.on_ground, pl.board = true, {s = s, hx = 1, hz = 0, k = 0}
	end
	-- Walked onto a slope down 30, flat after it, a wall of 3 at 80: the
	-- board by itself, the speed what the drop gives and kept on the flat,
	-- the wall a stop and a walk
	local hill = M.new(columns(function(x)
		if x < 0 then return 20 end
		if x < 30 then return 20 - x end
		if x >= 80 and x <= 81 then return -7 end
		return -10
	end))
	hill:set_position(-6, 20.5, 0)
	local boarded, top_speed, at_40 = false, 0, nil
	run(hill, {x = 1, z = 0, look_x = 1, look_z = 0}, 8, function(pl)
		if pl.board then
			boarded = true
			top_speed = math.max(top_speed, pl.board.s)
			if not at_40 and pl.x >= 40 then at_40 = pl.board.s end
		end
	end)
	local bound = math.sqrt(16 + 2 * g * 30)
	assert(boarded, "board: walking down a slope does not take the board")
	assert(top_speed <= bound * 1.01 and top_speed > bound * 0.9,
			"board: the speed down 30 is " .. top_speed .. ", not " .. bound)
	assert(at_40 and at_40 > bound * 0.9, "board: the flat slows it")
	assert(not hill.board and hill.x < 80 and hill.x > 78,
			"board: a step of 3 does not stop it, x " .. hill.x)
	-- The brake: from 10, a stop within 10^2 / (2 * brake) and a bit
	local flat = M.new(columns(function() return -1 end))
	board(flat, 0, -0.5, 10)
	run(flat, {x = 0, z = 0, look_x = 1, look_z = 0}, 0.5)
	assert(flat.board and math.abs(flat.board.s - 10) < 1e-6,
			"board: the flat slows it")
	local x0 = flat.x
	run(flat, {x = 0, z = 0, brake = true, look_x = 1, look_z = 0}, 3)
	assert(not flat.board and flat.x - x0 < 100 / (2 * M.BOARD_BRAKE) + 1,
			"board: the brake does not stop it")
	-- The jump: twice the walk's speed, four times its height
	board(flat, 0, -0.5, 5)
	local peak = -0.5
	run(flat, {x = 0, z = 0, jump = true, look_x = 1, look_z = 0}, 1 / 60)
	run(flat, {x = 0, z = 0, look_x = 1, look_z = 0}, 2, function(pl)
		peak = math.max(peak, pl.y)
	end)
	assert(peak + 0.5 > 3.5, "board: the jump is " .. (peak + 0.5) .. " high")
	assert(flat.board and flat.on_ground, "board: it does not land")
	-- A ramp up 4 and off its crest: flying, then on the board again
	local ramp = M.new(columns(function(x)
		return (x >= 10 and x <= 13) and x - 10 or -1
	end))
	board(ramp, 0, -0.5, 20)
	local flew = false
	run(ramp, {x = 0, z = 0, look_x = 1, look_z = 0}, 3, function(pl)
		if pl.board and not pl.on_ground and pl.x > 13 then flew = true end
	end)
	assert(flew and ramp.board and ramp.on_ground and ramp.x > 20,
			"board: no flight off the ramp")
	-- A step of 2 ridden up, the speed paid for it
	local step2 = M.new(columns(function(x) return x >= 5 and 1 or -1 end))
	board(step2, 0, -0.5, 10)
	run(step2, {x = 0, z = 0, look_x = 1, look_z = 0}, 1)
	-- [SKELDAT_BOARD_PRONE] A wall at x 10..11 three high with a hole one
	-- high at z 0: the board stops at it standing, passes it lying flat,
	-- stays flat in it after Shift is let go and stands once out; stopped
	-- in it, the player crawls out and stands
	local hole = function(x, y, z)
		if y <= -1 then return true end
		return x >= 10 and x <= 11 and y <= 2 and not (y == 0 and z == 0)
	end
	local go = {x = 0, z = 0, look_x = 1, look_z = 0}
	local flat_go = {x = 0, z = 0, look_x = 1, look_z = 0, sneak = true}
	local stand = M.new(hole)
	board(stand, 0, -0.5, 8)
	run(stand, go, 3)
	assert(not stand.board and stand.x < 9.8, "prone: the wall did not stop "
			.. "the board, x " .. stand.x)
	local low = M.new(hole)
	board(low, 0, -0.5, 8)
	run(low, flat_go, 3)
	assert(low.board and low.x > 14 and low.prone,
			"prone: no way through the hole lying flat, x " .. low.x)
	run(low, go, 0.2)
	assert(not low.prone and low.height == M.HEIGHT, "prone: not up again")
	local mid = M.new(hole)
	board(mid, 0, -0.5, 8)
	local flat_in, stood_out = true, false
	for _ = 1, 180 do
		mid:update(1 / 60, mid.x < 10.5 and flat_go or go)
		if mid.x > 9.8 and mid.x < 11.7 and not mid.prone then flat_in = false end
		if mid.x > 12.5 and not mid.prone then stood_out = true end
	end
	assert(flat_in and stood_out, "prone: let go in the hole, not flat in it "
			.. "or not up after it")
	local stuck = M.new(hole)
	board(stuck, 10.5, -0.5, 0.3)
	stuck.prone = true
	run(stuck, flat_go, 0.1)
	assert(not stuck.board and stuck.prone, "prone: stopped in the hole, "
			.. "not flat")
	run(stuck, {x = 1, z = 0}, 3)
	assert(stuck.x > 12 and not stuck.prone,
			"prone: no crawl out of the hole, x " .. stuck.x)
	assert(step2.board and math.abs(step2.y - 1.5) < 1e-6 and
			math.abs(step2.board.s - math.sqrt(100 - 2 * g * 2)) < 0.05,
			"board: a step of 2 not ridden, y " .. step2.y)
end

return M
-- vim: set noet ts=4 sw=4:
