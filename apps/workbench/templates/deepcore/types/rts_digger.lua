-- Deepcore's digger ([KIT_RTS], kit_plan 4z37zzo): ordered to a point, it digs
-- a tunnel there, `width` cells wide and `height` high, a cell a step along x
-- or z (the longer way first), at its own level (simplified: no ramps; the
-- slice's step up or down a cell, below, is their upgrade: a goal's level),
-- and drives into each slice it dug (c:propose_move: it is
-- before kit/unit on its entity, so its way wins while it digs). A slice takes
-- the slowest of its cells' times in `digs` ("<voxel> <seconds>, ..."); a
-- voxel not there (kit/hard_rock) it cannot dig: it tries the other way round,
-- then gives up there. Where the way is open it just drives. Its tunnels are
-- the World's cells (c:set_voxels_at, game changes), so the pathfinder takes
-- any unit through them.
-- simplified: straight runs along the grid, no diagonal; a slice's cells
-- dug at once after its time; it gives up after two blocked tries; diggers
-- ordered together all dig to the point clicked (not a spot each)
local function digs(s)
	local t = {}
	for name, sec in tostring(s):gmatch("([%w_/]+)%s+([%d%.]+)") do
		t[name] = tonumber(sec)
	end
	return t
end

local function cell(p)
	return {math.floor(p[1] + 0.5), math.floor(p[2] + 0.5), math.floor(p[3] + 0.5)}
end

local function sign(v)
	return v > 0 and 1 or v < 0 and -1 or 0
end

-- The next slice along step (sx, sz) from cell a, up or down by dy: its
-- cells, the time it takes, false if a cell cannot be dug
local function slice(c, a, sx, sz, dy, times)
	local w, h = c.params.width, c.params.height
	local nx, ny, nz = a[1] + sx, a[2] + dy, a[3] + sz
	-- across the way: x for a step along z, z for one along x
	local ax, az = sz ~= 0 and 1 or 0, sx ~= 0 and 1 or 0
	-- (the step's cell and the one before it across: a unit walks a cell's
	-- middle)
	local o = -math.floor(w / 2)
	local x0, z0 = nx + ax * o, nz + az * o
	-- up: the slice over the step (its cell at a's level the new floor);
	-- down: from the new level to the head of the old one
	local size = {ax == 1 and w or 1, h + (dy < 0 and 1 or 0), az == 1 and w or 1}
	local y0 = ny
	local names = c:voxels_at({x0, y0, z0}, size)
	local cells, t = {}, 0
	local i = 0
	for y = 0, size[2] - 1 do
		for z = 0, size[3] - 1 do
			for x = 0, size[1] - 1 do
				i = i + 1
				local n = names[i] or ""
				if n == "" then
					return nil, 0
				elseif n ~= "air" then
					local s = times[n]
					if not s then
						return false, 0, n
					end
					t = math.max(t, s)
					cells[#cells + 1] = {x0 + x, y0 + y, z0 + z, "air"}
				end
			end
		end
	end
	return cells, t, {nx, ny, nz}
end

local function step(c)
	local g = c.state.goal
	if type(g) ~= "table" then
		return
	end
	-- (at the goal's level: simplified, see above)
	local a = cell(c.pos)
	a[2] = g[2]
	local dx, dy, dz = g[1] - a[1], g[2] - a[2], g[3] - a[3]
	if math.abs(dx) + math.abs(dz) <= 0 then
		c.state.goal = false
		c:propose_move(nil)
		c:log("dug to " .. g[1] .. "," .. g[2] .. "," .. g[3])
		return
	end
	local times = digs(c.params.digs)
	local tries = math.abs(dx) >= math.abs(dz) and {{sign(dx), 0}, {0, sign(dz)}} or
		{{0, sign(dz)}, {sign(dx), 0}}
	for _, s in ipairs(tries) do
		if s[1] ~= 0 or s[2] ~= 0 then
			local cells, t, next = slice(c, a, s[1], s[2], sign(dy), times)
			if cells == nil then
				-- not loaded yet: again soon
				c:after(0.5, "dig")
				return
			elseif cells then
				c.state.next = next
				c.state.cells = cells
				c:after(math.max(0.1, t), "dug")
				return
			else
				c:log("cannot dig " .. tostring(next) .. " towards " .. g[1] .. "," .. g[3])
			end
		end
	end
	c.state.goal = false
	c:propose_move(nil)
	c:log("blocked by hard rock")
end

return {
	version = 1,
	about = {
		group = "Creatures",
		what = "A Deepcore digger: ordered to a point, it digs a tunnel there through what it can dig.",
		params = {
			digs = "What it digs and the seconds a slice of it takes: \"<voxel> <seconds>, ...\".",
			width = "The tunnel's width in cells.",
			height = "The tunnel's height in cells.",
		},
	},
	component = true,
	creature = true,
	world_voxels = true,
	params = {
		digs = {type = "string", default = "kit/dirt 0.4, kit/gravel 0.4, kit/sand 0.4, kit/stone 1.2, kit/ore 1.2, kit/cobble 1.2"},
		width = {type = "number", default = 2, min = 1, max = 3},
		height = {type = "number", default = 2, min = 2, max = 3},
	},
	state = {goal = {default = false}, next = {default = false},
		cells = {default = false}, waits = {default = 0}},
	on_order = function(c, order)
		-- (the point clicked, not its spot: a spot is moved out of walls)
		local at = order.center or order.at
		if at then
			local g = cell({at[1], c.pos[2], at[3]})
			c.state.goal = g
			c.state.waits = 0
			c:log("digging to " .. g[1] .. "," .. g[2] .. "," .. g[3])
			c:after(0.05, "dig")
		else
			c.state.goal = false
			c:propose_move(nil)
		end
	end,
	on_timer = function(c, name)
		if name == "dig" then
			step(c)
		elseif name == "dug" and type(c.state.goal) == "table" and
				type(c.state.cells) == "table" then
			local n = c.state.next
			if #c.state.cells > 0 then
				c:set_voxels_at(c.state.cells)
				c:log("dug " .. #c.state.cells .. " cells to " .. n[1] .. "," .. n[2] .. "," .. n[3])
			end
			c.state.cells = false
			c:propose_move({to = {n[1], n[2] - 0.5, n[3]}, range = 0.2})
			c:after(0.35, "go")
		elseif name == "go" and type(c.state.goal) == "table" then
			-- in the slice dug (or long enough waiting): the next one
			local n, p = c.state.next, c.pos
			local d = type(n) == "table" and math.abs(n[1] - p[1]) + math.abs(n[3] - p[3]) or 0
			if d > 0.6 and c.state.waits < 8 then
				c.state.waits = c.state.waits + 1
				c:after(0.25, "go")
			else
				c.state.waits = 0
				step(c)
			end
		end
	end,
}
