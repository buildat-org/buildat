-- Buildat: builtin/luanti/lua/raycast.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- core.raycast(pos1, pos2, objects, liquids, pointabilities): what a ray runs
-- into, nearest first. A mod uses it for everything a player points at and
-- for a good deal that nobody points at -- line of sight, a mob's eyes, where
-- a thrown thing lands.
--
-- The nodes are walked with Amanatides and Woo's grid march, which is what
-- Luanti's own RaycastState does: every node the ray passes through, in
-- order, with none skipped -- and "none skipped" is the whole point, since a
-- march that leaves a node out lets a thrown thing through a wall. devtest's
-- test_raycast_noskip fires a hundred random rays at a cube of dirt and
-- checks that what comes back has air in front of it.
--
-- simplified, and each is a rung rather than a hole:
--
--  * **a node is its selection boxes** (core.get_node_boxes), each
--    tested only while the ray is in the node's own cell: a box reaching
--    out of its cube is cut there ([VL_RAIL_BOXES]).
--  * **an object is its selection box, axis-aligned**, and its rotation is
--    not applied.
--  * **box_id** is not answered.

local M = {}

-- Luanti's own: a node is pointable, not pointable, or blocking -- which
-- stops the ray without being pointed at. A mod's pointabilities table says
-- so per node name or per group, over what the definition says.
local function node_pointable(name, def, pointabilities)
	local p = def and def.pointable
	if p == nil then
		p = true
	end
	local nodes = pointabilities and pointabilities.nodes
	if nodes then
		local v = nodes[name]
		if v == nil then
			for group, rating in pairs(def and def.groups or {}) do
				if rating ~= 0 and nodes["group:" .. group] ~= nil then
					v = nodes["group:" .. group]
					break
				end
			end
		end
		if v ~= nil then
			p = v
		end
	end
	return p
end

local function object_pointable(ref, pointabilities)
	local props = ref.get_properties and ref:get_properties() or nil
	local p = props and props.pointable
	if p == nil then
		p = true
	end
	local objects = pointabilities and pointabilities.objects
	if objects then
		local v = nil
		if ref.is_player and ref:is_player() then
			v = objects[ref:get_player_name()]
		else
			local le = ref.get_luaentity and ref:get_luaentity()
			if le and le.name then
				v = objects[le.name]
			end
		end
		if v ~= nil then
			p = v
		end
	end
	return p
end

-- Where a ray enters an axis-aligned box, or nil: the slab test, which is
-- the same one the client's own pointing uses.
local function box_entry(ox, oy, oz, dx, dy, dz, b, length)
	local t0, t1 = 0, length
	local axis = nil
	local function slab(o, d, lo, hi, which)
		if math.abs(d) < 1e-9 then
			return o >= lo and o <= hi
		end
		local a = (lo - o) / d
		local b2 = (hi - o) / d
		if a > b2 then
			a, b2 = b2, a
		end
		if a > t0 then
			t0 = a
			axis = which
		end
		if b2 < t1 then
			t1 = b2
		end
		return t0 <= t1
	end
	if not slab(ox, dx, b[1], b[4], "x") then return nil end
	if not slab(oy, dy, b[2], b[5], "y") then return nil end
	if not slab(oz, dz, b[3], b[6], "z") then return nil end
	if t0 < 0 or t0 > length then
		return nil
	end
	return t0, axis
end

-- The objects a ray could run into, each with how far along it is. Gathered
-- when the raycast is made, the way Luanti's own does, and checked again
-- when one is about to be answered: a callback that removes an object while
-- the ray is still being walked must not have it answered afterwards.
local function objects_along(pos1, dx, dy, dz, length, pointabilities)
	local out = {}
	-- A radius wide enough for anything a game draws, because an object's
	-- own box is what decides and this only narrows the list
	local middle = {x = pos1.x + dx * length / 2,
			y = pos1.y + dy * length / 2, z = pos1.z + dz * length / 2}
	for _, ref in ipairs(core.get_objects_inside_radius(middle,
			length / 2 + 8)) do
		local props = ref:get_properties() or {}
		local box = props.selectionbox or props.collisionbox or
				{-0.5, -0.5, -0.5, 0.5, 0.5, 0.5}
		local p = ref:get_pos()
		if p then
			local world = {p.x + box[1], p.y + box[2], p.z + box[3],
					p.x + box[4], p.y + box[5], p.z + box[6]}
			local t, axis = box_entry(pos1.x, pos1.y, pos1.z, dx, dy, dz,
					world, length)
			if t ~= nil and object_pointable(ref, pointabilities) then
				out[#out + 1] = {t = t, ref = ref, axis = axis}
			end
		end
	end
	table.sort(out, function(a, b) return a.t < b.t end)
	return out
end

local Raycast = {}
Raycast.__index = Raycast

local function normal_of(axis, d)
	if axis == "x" then
		return {x = d < 0 and 1 or -1, y = 0, z = 0}
	elseif axis == "y" then
		return {x = 0, y = d < 0 and 1 or -1, z = 0}
	elseif axis == "z" then
		return {x = 0, y = 0, z = d < 0 and 1 or -1}
	end
	return {x = 0, y = 0, z = 0}
end

function Raycast:next()
	if self.done then
		return nil
	end
	while true do
		-- Whatever is nearer: an object the ray has reached, or the node it
		-- is standing in
		local object = self.objects[self.object_i]
		if object ~= nil and object.t <= self.t then
			self.object_i = self.object_i + 1
			-- Gone since the ray was made, which a mod's own callback does
			if object.ref:get_pos() ~= nil then
				local at = {x = self.pos1.x + self.dx * object.t,
						y = self.pos1.y + self.dy * object.t,
						z = self.pos1.z + self.dz * object.t}
				local d = object.axis == "x" and self.dx or
						object.axis == "y" and self.dy or self.dz
				return {type = "object", ref = object.ref,
						intersection_point = vector.new(at.x, at.y, at.z),
						intersection_normal = vector.new(
								normal_of(object.axis, d or 0))}
			end
		elseif self.t > self.length then
			self.done = true
			return nil
		else
			local x, y, z = self.x, self.y, self.z
			local node = core.get_node({x = x, y = y, z = z})
			local name = node.name
			local def = core.registered_nodes[name]
			local liquid = def and def.liquidtype and
					def.liquidtype ~= "none" or false
			local pointable = node_pointable(name, def, self.pointabilities)
			local hit = nil
			if pointable == "blocking" then
				self.done = true
				return nil
			elseif pointable and (self.liquids or not liquid) then
				-- The nearest of its selection boxes, which Luanti's above
				-- is the face of: the node on the other side of it
				local boxes = core.get_node_boxes("selection_box",
						{x = x, y = y, z = z}, node)
				if #boxes == 0 then
					boxes = {{-0.5, -0.5, -0.5, 0.5, 0.5, 0.5}}
				end
				local best, axis = nil, nil
				for _, b in ipairs(boxes) do
					local t, a = box_entry(self.pos1.x, self.pos1.y,
							self.pos1.z, self.dx, self.dy, self.dz,
							{x + b[1], y + b[2], z + b[3],
							x + b[4], y + b[5], z + b[6]}, self.length)
					if t ~= nil and (best == nil or t < best) then
						best, axis = t, a
					end
				end
				if best ~= nil then
					local at = {x = self.pos1.x + self.dx * best,
							y = self.pos1.y + self.dy * best,
							z = self.pos1.z + self.dz * best}
					local d = axis == "x" and self.dx or
							axis == "y" and self.dy or self.dz
					local n = normal_of(axis, d or 0)
					hit = {type = "node", under = vector.new(x, y, z),
							above = vector.new(x + n.x, y + n.y, z + n.z),
							intersection_point = vector.new(at.x, at.y, at.z),
							intersection_normal = vector.new(n)}
				end
			end
			-- On to the next node whatever this one was
			self:advance()
			if hit ~= nil then
				return hit
			end
		end
	end
end

-- One step of Amanatides and Woo: the axis whose next boundary is nearest
function Raycast:advance()
	if self.tmax_x < self.tmax_y and self.tmax_x < self.tmax_z then
		self.t = self.tmax_x
		self.x = self.x + self.step_x
		self.tmax_x = self.tmax_x + self.tdelta_x
		self.axis = "x"
	elseif self.tmax_y < self.tmax_z then
		self.t = self.tmax_y
		self.y = self.y + self.step_y
		self.tmax_y = self.tmax_y + self.tdelta_y
		self.axis = "y"
	else
		self.t = self.tmax_z
		self.z = self.z + self.step_z
		self.tmax_z = self.tmax_z + self.tdelta_z
		self.axis = "z"
	end
end

function core.raycast(pos1, pos2, objects, liquids, pointabilities)
	local p1 = vector.new(pos1)
	local p2 = vector.new(pos2)
	local dx, dy, dz = p2.x - p1.x, p2.y - p1.y, p2.z - p1.z
	local length = math.sqrt(dx * dx + dy * dy + dz * dz)
	if length > 0 then
		dx, dy, dz = dx / length, dy / length, dz / length
	end
	local self = setmetatable({
		pos1 = p1, dx = dx, dy = dy, dz = dz, length = length,
		liquids = liquids and true or false,
		pointabilities = pointabilities,
		t = 0, axis = nil, done = false, object_i = 1,
	}, Raycast)
	-- Which node the ray starts in, and where each axis crosses out of it.
	-- A node is the cube around its own coordinates, so its faces are at
	-- the halves.
	self.x = math.floor(p1.x + 0.5)
	self.y = math.floor(p1.y + 0.5)
	self.z = math.floor(p1.z + 0.5)
	local function setup(o, d, node)
		if math.abs(d) < 1e-12 then
			return 0, math.huge, math.huge
		end
		local step = d > 0 and 1 or -1
		local face = node + step * 0.5
		return step, (face - o) / d, 1 / math.abs(d)
	end
	self.step_x, self.tmax_x, self.tdelta_x = setup(p1.x, dx, self.x)
	self.step_y, self.tmax_y, self.tdelta_y = setup(p1.y, dy, self.y)
	self.step_z, self.tmax_z, self.tdelta_z = setup(p1.z, dz, self.z)
	self.objects = objects and
			objects_along(p1, dx, dy, dz, length, pointabilities) or {}
	return self
end

-- for pt in core.raycast(...) do: a Lua for wants something it can call, and
-- Luanti's own Raycast userdata has the same __call
Raycast.__call = Raycast.next

-- Whether anything is in the way between two points, which is a raycast that
-- stops at the first node. Luanti answers where it stopped as well.
function core.line_of_sight(pos1, pos2, stepsize)
	local ray = core.raycast(pos1, pos2, false, false)
	for hit in ray do
		if hit.type == "node" then
			return false, hit.under
		end
	end
	return true
end

core.__raycast = M
