-- Crag Trial's bike drawn by the movement's draw hook (Kit's players.lua):
-- the frame, the wheels and the rider as boxes under the body's node, posed
-- from s.pose (crag_bike.lua's, by name: its angle, its facing, the wheels
-- from the feet and their turns), this client's own as predicted, the
-- others' as the server's last step left them; sized by the movement's
-- params (p: wheel, wheelbase, height)
local magic = require("buildat/extension/urho3d")
local kit = require("buildat/module/kit")
local log = buildat.Logger("crag_bike")
local said = false

local function part(root, name, model, color)
	local n = root:CreateChild(name)
	local m = n:CreateComponent("StaticModel")
	m.model = magic.cache:GetResource("Model", "Models/" .. model .. ".mdl")
	m.material = kit.material(color)
	m.castShadows = true
	return n
end

-- A box from a to b in the body's node, t thick (z depth d)
local function seg(n, a, b, t, d)
	local dx, dy = b[1] - a[1], b[2] - a[2]
	n.position = magic.Vector3((a[1] + b[1]) / 2, (a[2] + b[2]) / 2, 0)
	n.rotation = magic.Quaternion(0, 0, math.deg(math.atan2(dy, dx)))
	n.scale = magic.Vector3(math.sqrt(dx * dx + dy * dy) + t, t, d or t)
end

local function build(node)
	local b = node:CreateChild("crag_bike")
	for _, k in ipairs({"wl", "wr"}) do
		local wh = b:CreateChild(k)
		part(wh, "tyre", "Cylinder", "#26282b").rotation = magic.Quaternion(90, 0, 0)
		part(wh, "hub", "Cylinder", "#b8bcc0").rotation = magic.Quaternion(90, 0, 0)
		part(wh, "spoke", "Box", "#3a3d42")
	end
	for _, k in ipairs({"back", "down", "fork", "tank"}) do
		part(b, k, "Box", "#2a9d8f")
	end
	part(b, "seat", "Box", "#1d1f22")
	part(b, "bars", "Box", "#1d1f22")
	for _, k in ipairs({"leg", "shin", "torso", "arm"}) do
		part(b, k, "Box", k == "torso" and "#e9c46a" or "#3d5a80")
	end
	part(b, "head", "Sphere", "#f4f1ea").scale = magic.Vector3(0.44, 0.44, 0.44)
	return b
end

return {
	draw = function(s, node, _, p)
		local R, LIFT, AX = p.wheel, p.height, p.wheelbase / 2
		local q = type(s.pose) == "table" and s.pose or {}
		local a, dir = tonumber(q.a) or 0, tonumber(q.dir) or 1
		local dead = dir > 1 or dir < -1
		dir = dir < 0 and -1 or 1
		local b = node:GetChild("crag_bike", false) or build(node)
		if not said then
			said = true
			log:info("crag_bike: the draw hook draws a bike")
		end
		local ca, sa = math.cos(a), math.sin(a)
		-- A point of the frame (its middle 0, 0, facing +x) in the node
		local function at(x, y)
			x = x * dir
			return {x * ca - y * sa, LIFT + x * sa + y * ca}
		end
		-- (no pose yet: the wheels at rest)
		local wl, wr = {tonumber(q.lx) or -AX, tonumber(q.ly) or R},
			{tonumber(q.rx) or AX, tonumber(q.ry) or R}
		for k, wp in pairs({wl = wl, wr = wr}) do
			local n = b:GetChild(k, false)
			n.position = magic.Vector3(wp[1], wp[2], 0)
			n.rotation = magic.Quaternion(0, 0, math.deg(tonumber(q[k == "wl" and "tl" or "tr"]) or 0))
			-- (sized each frame: a set_param in play shows at once)
			n:GetChild("tyre", false).scale = magic.Vector3(2 * R, 0.16, 2 * R)
			n:GetChild("hub", false).scale = magic.Vector3(1.3 * R, 0.17, 1.3 * R)
			n:GetChild("spoke", false).scale = magic.Vector3(1.5 * R, 0.06, 0.18)
		end
		-- The wheels as the frame faces: the back one driven
		local back, front = dir > 0 and wl or wr, dir > 0 and wr or wl
		local seat, head = at(-0.2, 0.32), at(-0.08, 0.86)
		local bars, foot = at(0.42, 0.5), at(0.02, -0.06)
		seg(b:GetChild("back", false), back, at(-0.1, 0.12), 0.09)
		seg(b:GetChild("down", false), at(-0.1, 0.12), at(0.36, 0.38), 0.11)
		seg(b:GetChild("fork", false), front, bars, 0.08)
		seg(b:GetChild("tank", false), at(0.0, 0.3), at(0.32, 0.36), 0.2, 0.3)
		seg(b:GetChild("seat", false), at(-0.42, 0.3), at(-0.05, 0.3), 0.08, 0.3)
		seg(b:GetChild("bars", false), at(0.4, 0.5), at(0.42, 0.52), 0.06, 0.6)
		-- The rider: crashed, slumped over the bars
		local hip, sh = seat, dead and at(0.2, 0.45) or at(-0.02, 0.7)
		local knee = at(0.18, 0.18)
		seg(b:GetChild("leg", false), hip, knee, 0.14)
		seg(b:GetChild("shin", false), knee, foot, 0.12)
		seg(b:GetChild("torso", false), hip, sh, 0.24, 0.3)
		seg(b:GetChild("arm", false), sh, bars, 0.1)
		local hd = dead and at(0.34, 0.6) or head
		b:GetChild("head", false).position = magic.Vector3(hd[1], hd[2], 0)
	end,
}
