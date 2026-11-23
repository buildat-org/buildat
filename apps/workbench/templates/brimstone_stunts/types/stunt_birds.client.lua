-- stunt_birds' client part: the flock as nodes of its own under e.node, each
-- bird a body and two wings (boxes of one material: Urho3D instances them).
-- Sitting, nothing is done but the car's distance each 4th frame; within `scare`
-- of the flock's middle each bird takes off on a loop of its own (out away
-- from the car and round back, up and down: FLY seconds), wings flapping,
-- and lands where it sat; a car still near scatters them again.
-- simplified: a loop of a circle through its seat, not a flight that keeps
-- clear of the walls (they fly over them)
local magic = require("buildat/extension/urho3d")
local kit = require("buildat/module/kit")

local FLY, UP = 7, 7 -- seconds aloft, metres up at the loop's top
local flocks = {}

local function rng(seed)
	local x = seed % 2147483647
	if x <= 0 then
		x = x + 2147483646
	end
	return function()
		x = x * 16807 % 2147483647
		return x / 2147483647
	end
end

local function box(parent, pos, size, mat)
	local n = parent:CreateChild("bird part")
	n.position, n.scale = pos, size
	local m = n:CreateComponent("StaticModel")
	m.model = magic.cache:GetResource("Model", "Models/Box.mdl")
	m.material = mat
	m.castShadows = false
	m.drawDistance = 70 -- (a bird some pixels long past that)
	return n
end

return {
	on_add = function(e)
		local p = e.params
		local rand = rng(e.id * 7919 + 13)
		local mat = kit.material(type(p.color) == "string" and p.color or "#26262c")
		local f = {birds = {}, t = 0, flying = false, scare = tonumber(p.scare) or 14}
		local spread = tonumber(p.spread) or 5
		for k = 1, math.max(1, math.min(64, tonumber(p.count) or 28)) do
			local a, r = rand() * 2 * math.pi, spread * math.sqrt(rand())
			local hx, hz = math.cos(a) * r, math.sin(a) * r
			local yaw = rand() * 360
			local node = e.node:CreateChild("bird")
			node.position = magic.Vector3(hx, 0.12, hz)
			node.rotation = magic.Quaternion(0, yaw, 0)
			box(node, magic.Vector3(0, 0, 0), magic.Vector3(0.16, 0.14, 0.4), mat)
			local wl = node:CreateChild("wing")
			local wr = node:CreateChild("wing")
			wl.position, wr.position = magic.Vector3(-0.06, 0.05, 0), magic.Vector3(0.06, 0.05, 0)
			box(wl, magic.Vector3(-0.22, 0, 0), magic.Vector3(0.44, 0.025, 0.2), mat)
			box(wr, magic.Vector3(0.22, 0, 0), magic.Vector3(0.44, 0.025, 0.2), mat)
			-- (folded at rest)
			wl.rotation, wr.rotation = magic.Quaternion(0, 0, -50), magic.Quaternion(0, 0, 50)
			f.birds[k] = {node = node, wl = wl, wr = wr, hx = hx, hz = hz, yaw = yaw,
				size = 0.6 + rand() * 0.6, phase = rand() * 6.28, rate = 16 + rand() * 8,
				delay = rand() * 0.6, up = UP * (0.6 + rand() * 0.8)}
		end
		flocks[e.id] = f
	end,
	on_update = function(e, dt)
		local f = flocks[e.id]
		if not f then
			return
		end
		if not f.flying then
			-- (sitting: looked at each 4th frame, a read through the sandbox
			-- dear; the car comes some 4 m nearer meanwhile at most)
			f.skip = ((f.skip or e.id) + 1) % 4
			local car = f.skip == 0 and kit.body_pos()
			local at = car and e.node.worldPosition
			if car then
				local dx, dz = car.x - at.x, car.z - at.z
				if dx * dx + dz * dz < f.scare * f.scare then
					-- Away from the car: each loop's way out, a little apart
					local away = math.atan2(-dx, -dz)
					for k, b in ipairs(f.birds) do
						local a = away + (math.fmod(k * 2.39996, 1.6) - 0.8)
						b.dx, b.dz = math.sin(a), math.cos(a)
						b.side = k % 2 == 0 and 1 or -1
					end
					f.flying, f.t = true, 0
					f.scares = (f.scares or 0) + 1
					e:log(string.format("stunt_birds: %d birds scatter from the car at %.1f,%.1f",
							#f.birds, car.x, car.z))
				end
			end
			return
		end
		f.t = f.t + dt
		local landed = true
		for _, b in ipairs(f.birds) do
			local u = (f.t - b.delay) / FLY
			if u < 1 then
				landed = false
			end
			u = math.max(0, math.min(1, u))
			-- A loop of a circle through the seat: out along (dx, dz), round
			-- by `side`, back; up and down along it
			local D = 9 * b.size + 6
			local c, s = math.cos(2 * math.pi * u), math.sin(2 * math.pi * u)
			local ox = D / 2 * (b.dx * (1 - c) + b.dz * b.side * s)
			local oz = D / 2 * (b.dz * (1 - c) - b.dx * b.side * s)
			local tx = b.dx * s + b.dz * b.side * c
			local tz = b.dz * s - b.dx * b.side * c
			local y = 0.12 + b.up * math.sin(math.pi * u)
			b.node.position = magic.Vector3(b.hx + ox, y, b.hz + oz)
			if u > 0 and u < 1 then
				b.node.rotation = magic.Quaternion(0, math.deg(math.atan2(tx, tz)), 0)
				local flap = 45 * math.sin(f.t * b.rate + b.phase)
				b.wl.rotation = magic.Quaternion(0, 0, flap)
				b.wr.rotation = magic.Quaternion(0, 0, -flap)
			end
		end
		if landed then
			f.flying = false
			for _, b in ipairs(f.birds) do
				b.node.rotation = magic.Quaternion(0, b.yaw, 0)
				b.wl.rotation, b.wr.rotation = magic.Quaternion(0, 0, -50), magic.Quaternion(0, 0, 50)
			end
			e:log("stunt_birds: the flock sat down again")
		end
	end,
	on_remove = function(e)
		local f = flocks[e.id]
		if f then
			for _, b in ipairs(f.birds) do
				b.node:Remove()
			end
		end
		flocks[e.id] = nil
	end,
}
