-- stunt_fans' client part: the fans as nodes under e.node, turned by
-- `facing`, along the stand's width in `rows` up its slope (a wedge's: its
-- top from 0 at the front, -z, to the height at the back), each a shirt and
-- a head, an arm raised by some. Still while no car is near (nothing but
-- the distance each 4th frame); within `near` they hop, in HOPS groups each
-- at its own pace (a node a group: a write each a frame, not one a fan), and
-- settle again once it has gone.
local magic = require("buildat/extension/urho3d")
local kit = require("buildat/module/kit")

local SHIRTS = {"#c8102e", "#f2c200", "#1f5fbf", "#f4f1e8", "#2c8a3c", "#e06a10", "#5a2a82"}
local SKIN = {"#f0c8a0", "#c68e62", "#8a5a3a", "#e8b090"}
local HOPS = 5
local stands = {}

local function box(parent, pos, size, mat)
	local n = parent:CreateChild("fan part")
	n.position, n.scale = pos, size
	local m = n:CreateComponent("StaticModel")
	m.model = magic.cache:GetResource("Model", "Models/Box.mdl")
	m.material = mat
	m.castShadows = false
	m.drawDistance = 100 -- (a fan some pixels high past that)
	return n
end

return {
	on_add = function(e)
		local p = e.params
		local sz = type(p.size) == "table" and p.size or {16, 2.4, 4}
		local w, h, d = tonumber(sz[1]) or 16, tonumber(sz[2]) or 2.4, tonumber(sz[3]) or 4
		local rows = math.max(1, math.min(6, math.floor(tonumber(p.rows) or 3)))
		local root = e.node:CreateChild("fans")
		root.rotation = magic.Quaternion(0, tonumber(p.facing) or 0, 0)
		local st = {root = root, fans = {}, hops = {}, near = tonumber(p.near) or 30, t = 0}
		for g = 1, HOPS do
			st.hops[g] = {node = root:CreateChild("fans hopping"), phase = g * 1.7,
				rate = 9 + g * 0.83 % 4}
		end
		local k = 0
		for j = 1, rows do
			local z = -d / 2 + (j - 0.5) * d / rows
			-- (the wedge's top there, from its bottom: the stand's middle is the node)
			local y = -h / 2 + h * (j - 0.5) / rows
			local n = math.floor(w / 0.75)
			for i = 1, n do
				k = k + 1
				local x = -w / 2 + (i - 0.5) * w / n + (k * 0.37 % 0.3 - 0.15)
				local fan = st.hops[k % HOPS + 1].node:CreateChild("fan")
				fan.position = magic.Vector3(x, y, z)
				fan.rotation = magic.Quaternion(0, 180 + (k * 37 % 30 - 15), 0)
				local shirt = kit.material(SHIRTS[k * 5 % #SHIRTS + 1])
				box(fan, magic.Vector3(0, 0.3, 0), magic.Vector3(0.42, 0.6, 0.28), shirt)
				box(fan, magic.Vector3(0, 0.74, 0), magic.Vector3(0.24, 0.26, 0.24),
						kit.material(SKIN[k * 3 % #SKIN + 1]))
				if k % 3 == 0 then
					box(fan, magic.Vector3(0.26, 0.82, 0), magic.Vector3(0.1, 0.5, 0.1), shirt)
				end
				st.fans[k] = fan
			end
		end
		stands[e.id] = st
	end,
	on_update = function(e, dt)
		local st = stands[e.id]
		if not st then
			return
		end
		-- (still: looked at each 4th frame, a read through the sandbox dear)
		st.skip = ((st.skip or e.id) + 1) % 4
		if not st.cheering and st.skip ~= 0 then
			return
		end
		local near = e:near(st.near)
		if not near and not st.cheering then
			return
		end
		if near and not st.cheering then
			e:log("stunt_fans: " .. #st.fans .. " fans cheer")
		end
		st.cheering = near or nil
		st.t = st.t + dt
		for _, g in ipairs(st.hops) do
			local hop = near and 0.28 * math.abs(math.sin(st.t * g.rate + g.phase)) or 0
			g.node.position = magic.Vector3(0, hop, 0)
		end
	end,
	on_remove = function(e)
		local st = stands[e.id]
		if st then
			st.root:Remove()
		end
		stands[e.id] = nil
	end,
}
