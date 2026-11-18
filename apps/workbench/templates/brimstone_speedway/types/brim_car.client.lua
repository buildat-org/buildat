-- Brimstone Speedway's car drawn by the movement's draw hook (Kit's
-- players.lua): a classic American car seen from above, made of flat
-- polygons extruded up (one CustomGeometry, a geometry a colour): a long
-- hood, the cabin, tail fins, chrome bumpers, two-tone paint (s.pose[2]:
-- the race's paint for the player, 1...6), headlights and tail lights, four
-- wheels where the movement's tyres are, the front ones steered. Wrecked
-- (pose flag 2) it is charred black. Facing +z, turned by the pose's
-- heading. Its effects from the pose (brim_car.lua's head): exhaust smoke
-- (more on the throttle), road dust by the floor and the speed, sparks
-- where it scrapes a wall, flames out of the back boosted, tyre marks
-- where a tyre slips much (coloured by the floor), and on this player's own
-- car the camera shaken in the frame its predicted step hits a wall hard.
local magic = require("buildat/extension/urho3d")
local log = buildat.Logger("brim_car")
local said = false
local mats = {}

-- Paint: {body, the top's second tone}
local PAINTS = {
	{"#b3121f", "#f2ead8"}, -- fire-engine red over cream
	{"#1d4e89", "#e8e2d0"}, -- midnight blue over cream
	{"#0f7a5a", "#f0e6c8"}, -- sea-foam green over cream
	{"#e0a21b", "#1b1b1b"}, -- school-bus gold over black
	{"#6b2d82", "#f0d0e8"}, -- grape over pink
	{"#e7e3dc", "#c4161c"}, -- cream over red
}
local CHROME, GLASS, TYRE = "#d9dee4", "#1a2633", "#141414"
local CHAR = "#2a2420"
-- The pose's floor (brim_car.lua's SURF): dust and marks
local DUST = {"#9a7a52", "#5a4630", nil, "#8a8478", "#9a7a52"}
local MARK = {"#2e2216", "#1e1610", "#0a0a0c", "#151515", "#2e2216"}

local function mat(hex)
	if not mats[hex] then
		local m = magic.Material:new()
		m:SetTechnique(0, magic.cache:GetResource("Technique",
				"Techniques/NoTexture.xml"))
		m:SetShaderParameter("MatDiffColor", magic.Color(tonumber(hex:sub(2, 3), 16) / 255,
				tonumber(hex:sub(4, 5), 16) / 255, tonumber(hex:sub(6, 7), 16) / 255))
		mats[hex] = m
	end
	return mats[hex]
end

-- The parts: a convex outline {x, z...} (x right, z ahead), its bottom and
-- top (m), its colour's role: "a" the paint, "b" the second tone, else a
-- colour
local PARTS = {
	{{-0.92, 2.2, 0.92, 2.2, 1.0, 1.65, 1.0, -1.85, 0.86, -2.12, -0.86, -2.12,
		-1.0, -1.85, -1.0, 1.65}, 0.28, 0.72, "a"},
	-- The fins, swept back past the trunk
	{{0.78, -0.9, 1.02, -1.15, 1.12, -2.4, 0.84, -2.15}, 0.5, 0.98, "a"},
	{{-0.78, -0.9, -0.84, -2.15, -1.12, -2.4, -1.02, -1.15}, 0.5, 0.98, "a"},
	-- The hood and the trunk lid in the second tone, the cabin's roof too
	{{-0.74, 2.08, 0.74, 2.08, 0.82, 0.78, -0.82, 0.78}, 0.72, 0.76, "b"},
	{{-0.66, -1.25, 0.66, -1.25, 0.62, -1.98, -0.62, -1.98}, 0.72, 0.76, "b"},
	{{-0.78, 0.38, 0.78, 0.38, 0.8, -0.82, -0.8, -0.82}, 0.72, 1.28, "b"},
	-- The windscreen and the back window
	{{-0.74, 0.74, 0.74, 0.74, 0.79, 0.38, -0.79, 0.38}, 0.72, 1.18, GLASS},
	{{-0.79, -0.82, 0.79, -0.82, 0.72, -1.2, -0.72, -1.2}, 0.72, 1.14, GLASS},
	-- Chrome bumpers and the grille
	{{-0.98, 2.18, 0.98, 2.18, 0.92, 2.42, -0.92, 2.42}, 0.24, 0.56, CHROME},
	{{-0.9, -2.1, 0.9, -2.1, 0.84, -2.32, -0.84, -2.32}, 0.24, 0.52, CHROME},
	{{-0.5, 2.16, 0.5, 2.16, 0.5, 2.24, -0.5, 2.24}, 0.4, 0.66, CHROME},
	-- A chrome spear along each side
	{{0.98, 1.4, 1.03, 1.4, 1.03, -1.4, 0.98, -1.4}, 0.5, 0.58, CHROME},
	{{-1.03, 1.4, -0.98, 1.4, -0.98, -1.4, -1.03, -1.4}, 0.5, 0.58, CHROME},
	-- Headlights and tail lights
	{{0.6, 2.2, 0.86, 2.2, 0.86, 2.3, 0.6, 2.3}, 0.5, 0.74, "#fff4c0"},
	{{-0.86, 2.2, -0.6, 2.2, -0.6, 2.3, -0.86, 2.3}, 0.5, 0.74, "#fff4c0"},
	{{0.9, -2.2, 1.1, -2.36, 1.08, -2.42, 0.88, -2.26}, 0.6, 1.0, "#ff2a14"},
	{{-0.9, -2.2, -0.88, -2.26, -1.08, -2.42, -1.1, -2.36}, 0.6, 1.0, "#ff2a14"},
}
-- The wheels: x, z, front
local WHEELS = {{0.92, 1.3, true}, {-0.92, 1.3, true}, {0.92, -1.25},
	{-0.92, -1.25}}

local function tri(cg, a, b, c, n)
	local e1x, e1y, e1z = b[1] - a[1], b[2] - a[2], b[3] - a[3]
	local e2x, e2y, e2z = c[1] - a[1], c[2] - a[2], c[3] - a[3]
	if (e1y * e2z - e1z * e2y) * n[1] + (e1z * e2x - e1x * e2z) * n[2] +
			(e1x * e2y - e1y * e2x) * n[3] < 0 then
		b, c = c, b
	end
	local nv = magic.Vector3(n[1], n[2], n[3])
	for _, p in ipairs({a, b, c}) do
		cg:DefineVertex(magic.Vector3(p[1], p[2], p[3]))
		cg:DefineNormal(nv)
	end
end

-- A convex outline extruded from y0 to y1 into geometry g
local function prism(cg, g, pts, y0, y1)
	cg:BeginGeometry(g, magic.TRIANGLE_LIST)
	local k = #pts / 2
	local function P(i, y)
		return {pts[2 * i - 1], y, pts[2 * i]}
	end
	for i = 2, k - 1 do
		tri(cg, P(1, y1), P(i, y1), P(i + 1, y1), {0, 1, 0})
	end
	for i = 1, k do
		local j = i % k + 1
		local ex, ez = pts[2 * j - 1] - pts[2 * i - 1], pts[2 * j] - pts[2 * i]
		local l = math.sqrt(ex * ex + ez * ez)
		if l > 1e-6 then
			-- (outward whichever way it winds: away from the middle)
			local nx, nz = ez / l, -ex / l
			local mx, mz = 0, 0
			for q = 1, k do
				mx, mz = mx + pts[2 * q - 1] / k, mz + pts[2 * q] / k
			end
			if (pts[2 * i - 1] - mx) * nx + (pts[2 * i] - mz) * nz < 0 then
				nx, nz = -nx, -nz
			end
			local n = {nx, 0, nz}
			tri(cg, P(i, y0), P(j, y0), P(j, y1), n)
			tri(cg, P(i, y0), P(j, y1), P(i, y1), n)
		end
	end
end

local function paint_of(paint, wrecked)
	local p = PAINTS[paint] or PAINTS[1]
	return function(role)
		if wrecked then
			return role == GLASS and "#0c0c0c" or CHAR
		end
		return role == "a" and p[1] or role == "b" and p[2] or role
	end
end

local function build(node, paint, wrecked)
	local b = node:CreateChild("brim_car_" .. (paint * 10 + (wrecked and 1 or 0)))
	local body = b:CreateChild("body")
	local cg = body:CreateComponent("CustomGeometry")
	cg:SetNumGeometries(#PARTS)
	local col = paint_of(paint, wrecked)
	for g, part in ipairs(PARTS) do
		prism(cg, g - 1, part[1], part[2], part[3])
	end
	cg:Commit()
	for g, part in ipairs(PARTS) do
		cg:SetMaterial(g - 1, mat(col(part[4])))
	end
	cg.castShadows = true
	for k, wh in ipairs(WHEELS) do
		local n = body:CreateChild("wheel" .. k)
		n.position = magic.Vector3(wh[1], 0.34, wh[2])
		local m = n:CreateComponent("StaticModel")
		m.model = magic.cache:GetResource("Model", "Models/Box.mdl")
		m.material = mat(TYRE)
		n.scale = magic.Vector3(0.3, 0.66, 0.78)
	end
	return b
end

-- [RACER_FEEL] The effects go through Kit's client part effects (kit_plan
-- 4z37c (2) the camera shake, (3) particles and marks) once those are in;
-- till then each kind is only logged, once.
local said_fx = {}
local function stub(kind)
	if not said_fx[kind] then
		said_fx[kind] = true
		log:info("brim_car: effect " .. kind)
	end
end
-- A puff of particles: kind (smoke, dust, spark, flame) at x, y, z, its
-- colour, drifting along dx, dz
local function puff(kind, x, y, z, color, dx, dz)
	stub(kind)
end
-- A tyre mark on the floor at x, z along the heading h, its colour
local function mark(x, z, h, color)
	stub("mark")
end
-- This client's camera shaken (amount: about metres)
local function shake(amount)
	stub("shake")
end

local function bit(n, b)
	return math.floor(n / b) % 2 == 1
end

-- Each drawn car's effects' clocks, by its node.
-- simplified: never dropped (the sandbox has no weak tables): a few numbers
-- for each body this client has drawn
local fx = {}
local function effects(s, node, p, h, flags)
	local now = buildat.get_time_us() / 1e6
	local e = fx[node]
	if not e then
		e = {t = now, smoke = 0, dust = 0, run = 0, bumps = tonumber(s.bumps)}
		fx[node] = e
	end
	local dt = math.min(0.1, now - e.t)
	e.t = now
	local at = node.position
	local x, y, z = at.x, at.y, at.z
	local sh, ch = math.sin(h), math.cos(h)
	local function world(lx, lz)
		return x + lx * ch + lz * sh, z - lx * sh + lz * ch
	end
	local speed = tonumber(p[5]) or 0
	local surf = math.floor(tonumber(p[6]) or 1)
	-- Exhaust smoke out of the tail pipe, thicker on the throttle
	e.smoke = e.smoke + dt * (bit(flags, 32) and 14 or 3)
	if e.smoke >= 1 then
		e.smoke = 0
		local px, pz = world(0.55, -2.45)
		puff("smoke", px, y + 0.4, pz, "#5a5450", -sh, -ch)
	end
	if bit(flags, 1) then
		local px, pz = world(0, -2.6)
		puff("flame", px, y + 0.5, pz, "#ff8a1a", -sh, -ch)
	end
	-- Dust off the rear tyres by the speed (none off oil), more sliding
	if DUST[surf] and speed > 3 then
		e.dust = e.dust + dt * speed * (bit(flags, 4) and 1.6 or 0.6)
		if e.dust >= 1 then
			e.dust = 0
			for _, side in ipairs({0.92, -0.92}) do
				local px, pz = world(side, -1.6)
				puff("dust", px, y + 0.2, pz, DUST[surf], -sh, -ch)
			end
		end
	end
	-- Sparks where it scrapes
	for b, lz in pairs({[64] = 2.3, [128] = -2.3}) do
		if bit(flags, b) then
			local px, pz = world(0, lz)
			puff("spark", px, y + 0.5, pz, "#ffd23c", -sh, -ch)
		end
	end
	-- Marks: each slipping tyre's every 0.4 m
	local slips = math.floor(tonumber(p[7]) or 0)
	e.run = e.run + speed * dt
	if slips > 0 and e.run >= 0.4 then
		e.run = 0
		for k, wh in ipairs(WHEELS) do
			if bit(slips, 2 ^ (k - 1)) then
				local px, pz = world(wh[1], wh[2])
				mark(px, pz, h, MARK[surf] or MARK[1])
			end
		end
	end
	-- This player's own car (its predicted state): shaken at once on a hard hit
	if s.c and tonumber(s.bumps) and s.bumps ~= e.bumps then
		e.bumps = s.bumps
		shake(math.min(1, (tonumber(s.bump_v) or 8) / 20))
	end
end

return {
	draw = function(s, node)
		local p = type(s.pose) == "table" and s.pose or {}
		local h = tonumber(p[1]) or 0
		local paint = math.floor(tonumber(p[2]) or 1)
		paint = PAINTS[paint] and paint or 1
		local steer = (tonumber(p[3]) or 0) * 180 / math.pi
		local flags = math.floor(tonumber(p[4]) or 0)
		local wrecked = math.floor(flags / 2) % 2 == 1
		local look = paint * 10 + (wrecked and 1 or 0)
		-- (its look by its child's name: another paint or the wreck built anew)
		local b = node:GetChild("brim_car_" .. look, false)
		if not b then
			for k = 1, #PAINTS do
				for _, x in ipairs({0, 1}) do
					local old = node:GetChild("brim_car_" .. (k * 10 + x), false)
					if old then
						old:Remove()
					end
				end
			end
			b = build(node, paint, wrecked)
		end
		if not said then
			said = true
			log:info("brim_car: the draw hook draws a car")
		end
		local body = b:GetChild("body", false)
		body.rotation = magic.Quaternion(0, h * 180 / math.pi, 0)
		for k = 1, 2 do
			body:GetChild("wheel" .. k, false).rotation = magic.Quaternion(0, steer, 0)
		end
		effects(s, node, p, h, flags)
	end,
}
