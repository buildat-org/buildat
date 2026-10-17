-- Buildat: apps/demo_skeldat/main/client_lua/hand.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- **The wielded item** ([SKELDAT_BOW]): drawn in front of the camera as
-- builtin/luanti's client draws it (wield.lua: an item's picture extruded,
-- a node's cube, official's place), lit by the light where the player
-- stands. The bow is no picture but a mesh built from the draw: two limbs
-- bending on circular arcs, the string of a fixed length from the tips to
-- the nock, and the nocked arrow pulled back with it; drawn, it comes up
-- before the eye.
--   local hand = run_script_file("main/hand.lua")
--   hand.new(camera_node, wield, game) -> h; h:update(dt, item, draw, light)
-- M.bow_shape() is plain Lua with its own self test:
--   luajit -e 'assert(dofile("apps/demo_skeldat/main/client_lua/hand.lua").self_test())'
-- simplified: no swing, no bob, no switching animation
local M = {}

-- The bow, a unit tall at rest, in its own frame: the grip at the origin,
-- the limbs along +-y, bulging to +z (where it shoots), the string on -z.
-- Each limb an arc of LIMB, bent through an angle; the string's length L
-- is the straight line between the tips at rest (a braced bow's string,
-- simplified with no brace height), and the nock's place follows from
-- where the tips are: half of L from each.
local LIMB, BEND0, BEND_MAX, PULL = 0.5, 0.45, 1.5, 0.42
local function tips(bend)
	local r = LIMB / bend
	return r * math.sin(bend), -r * (1 - math.cos(bend))
end
local HALF_L = (tips(BEND0))

-- The shape at draw d (0 to 1): the bend, a tip's (y, z) (the other's y
-- the negative), the nock's z and the string's length; the bend solved so
-- the nock is d * PULL behind the rest string's line
function M.bow_shape(d)
	local _, z0 = tips(BEND0)
	local want = z0 - d * PULL
	local function nock(bend)
		local y, z = tips(bend)
		return z - math.sqrt(math.max(0, HALF_L * HALF_L - y * y))
	end
	local lo, hi = BEND0, BEND_MAX
	for _ = 1, 40 do
		local mid = (lo + hi) / 2
		if nock(mid) > want then lo = mid else hi = mid end
	end
	local bend = (lo + hi) / 2
	local ty, tz = tips(bend)
	local nz = nock(bend)
	return {bend = bend, tip_y = ty, tip_z = tz, nock_z = nz,
		string = 2 * math.sqrt(ty * ty + (tz - nz) ^ 2)}
end

function M.self_test()
	local rest, half, full = M.bow_shape(0), M.bow_shape(0.5), M.bow_shape(1)
	for _, s in ipairs({rest, half, full}) do
		assert(math.abs(s.string - 2 * HALF_L) < 1e-6, "the string's length")
	end
	assert(rest.nock_z > half.nock_z and half.nock_z > full.nock_z and
			full.nock_z < -0.3, "the nock behind the grip, more as drawn")
	assert(math.abs((rest.nock_z - full.nock_z) - PULL) < 1e-6)
	assert(full.tip_y < half.tip_y and half.tip_y < rest.tip_y,
			"the tips in from the rest span")
	assert(full.bend > rest.bend)
	return true
end

if not buildat then
	return M
end

local magic = require("buildat/extension/urho3d")
local log = buildat.Logger("skeldat")

-- The colours, plain: the limbs the inventory picture's browns, the string
-- off-white, the head iron grey, the vanes white
local COLOURS = {{0.28, 0.17, 0.08}, {0.92, 0.90, 0.84}, {0.55, 0.56, 0.58},
	{0.97, 0.97, 0.97}}

-- The mesh at draw d into cg: geometry 0 the limbs and the grip, 1 the
-- string, 2 the arrow's shaft and head, 3 its vanes; arrow false leaves
-- it out
local function build_bow(cg, d, arrow)
	local s = M.bow_shape(d)
	local r = LIMB / s.bend
	cg:SetNumGeometries(4)
	local function tri(a, b, c)
		local ux, uy, uz = b[1] - a[1], b[2] - a[2], b[3] - a[3]
		local vx, vy, vz = c[1] - a[1], c[2] - a[2], c[3] - a[3]
		local nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz,
				ux * vy - uy * vx
		local l = math.sqrt(nx * nx + ny * ny + nz * nz)
		l = l > 0 and l or 1
		local n = magic.Vector3(nx / l, ny / l, nz / l)
		for _, p in ipairs({a, b, c, a, c, b}) do
			cg:DefineVertex(magic.Vector3(p[1], p[2], p[3]))
			cg:DefineNormal(n)
			cg:DefineTexCoord(magic.Vector2(0, 0))
		end
	end
	local function quad(a, b, c, e)
		tri(a, b, c)
		tri(a, c, e)
	end
	-- A strip of half-width w across x along the points
	local function strip(points, widths)
		for i = 1, #points - 1 do
			local p, q = points[i], points[i + 1]
			local w0, w1 = widths[i], widths[i + 1]
			quad({p[1] - w0, p[2], p[3]}, {p[1] + w0, p[2], p[3]},
					{q[1] + w1, q[2], q[3]}, {q[1] - w1, q[2], q[3]})
		end
	end
	cg:BeginGeometry(0, magic.TRIANGLE_LIST)
	local SEG = 16
	for side = -1, 1, 2 do
		local points, widths = {}, {}
		for i = 0, SEG do
			local a = s.bend * i / SEG
			-- And the limb's own thickness, a second strip turned a quarter
			points[#points + 1] = {0, side * r * math.sin(a), -r * (1 - math.cos(a)) +
					0.035}
			widths[#widths + 1] = 0.035 * (1 - 0.6 * i / SEG)
		end
		strip(points, widths)
	end
	-- The grip, a block round the origin
	local g = 0.045
	quad({-g, -0.08, 0}, {g, -0.08, 0}, {g, 0.08, 0}, {-g, 0.08, 0})
	quad({-g, -0.08, 0.07}, {-g, 0.08, 0.07}, {g, 0.08, 0.07}, {g, -0.08, 0.07})
	cg:BeginGeometry(1, magic.TRIANGLE_LIST)
	local sw = 0.006
	for side = -1, 1, 2 do
		strip({{0, side * s.tip_y, s.tip_z + 0.035}, {0, 0, s.nock_z + 0.035}},
				{sw, sw})
	end
	cg:BeginGeometry(2, magic.TRIANGLE_LIST)
	cg:BeginGeometry(3, magic.TRIANGLE_LIST)
	if arrow then
		-- The shaft from the nock forward over the grip, beside it
		local x, n0, n1 = 0.05, s.nock_z + 0.035, s.nock_z + 0.035 + 0.85
		local h = 0.008
		cg:BeginGeometry(2, magic.TRIANGLE_LIST)
		quad({x - h, 0, n0}, {x + h, 0, n0}, {x + h, 0, n1}, {x - h, 0, n1})
		quad({x, -h, n0}, {x, h, n0}, {x, h, n1}, {x, -h, n1})
		-- The head, two crossed diamonds
		local hw, hl = 0.03, 0.08
		quad({x - hw, 0, n1}, {x, 0, n1 - 0.02}, {x + hw, 0, n1}, {x, 0, n1 + hl})
		quad({x, -hw, n1}, {x, 0, n1 - 0.02}, {x, hw, n1}, {x, 0, n1 + hl})
		cg:BeginGeometry(3, magic.TRIANGLE_LIST)
		-- Three vanes behind, a third of a turn apart
		for k = 0, 2 do
			local a = math.rad(90 + 120 * k)
			local cx, cy = math.cos(a) * 0.035, math.sin(a) * 0.035
			quad({x, 0, n0 + 0.02}, {x + cx, cy, n0 + 0.05},
					{x + cx, cy, n0 + 0.16}, {x, 0, n0 + 0.18})
		end
	end
	cg:Commit()
end

-- The wielded item's node under camera_node; wield is wield.lua, game
-- init.lua's shared state (game.items for the pictures)
function M.new(camera_node, wield, game)
	local h = {node = camera_node:CreateChild("hand"), shapes = {},
		item = nil, draw = -1, arrow = nil, light = nil}
	local holder = h.node:CreateChild("item")
	local base = wield.place(h.node, 72)

	local function material(texture, colour)
		local m = magic.Material.new()
		if texture then
			m:SetTechnique(0, magic.cache:GetResource("Technique",
					"luanti_client/res/LuantiUnlitMask.xml"))
			local t = magic.cache:GetResource("Texture2D", texture)
			if t then
				t.filterMode = magic.FILTER_NEAREST
				m:SetTexture(magic.TU_DIFFUSE, t)
			end
		else
			m:SetTechnique(0, magic.cache:GetResource("Technique",
					"Techniques/NoTextureUnlit.xml"))
		end
		return {m = m, colour = colour or {1, 1, 1}}
	end

	-- The shape for an item, built once: its picture extruded, or the bow
	local function shape(name)
		if h.shapes[name] ~= nil then
			return h.shapes[name]
		end
		local d = game.items[name]
		local node = holder:CreateChild("shape")
		local cg = node:CreateComponent("CustomGeometry")
		local sh = {node = node, cg = cg, mats = {}}
		if name == "skeldat:bow" then
			sh.bow = true
			for i, c in ipairs(COLOURS) do
				sh.mats[i] = material(nil, c)
			end
		else
			local img = d and d.image and
					magic.cache:GetResource("Image", d.image)
			if not img or img.width == 0 then
				node:Remove()
				return nil -- asked again: the file may not be in yet
			end
			wield.extrude(cg, img)
			sh.mats[1] = material(d.image)
			cg:SetMaterial(0, sh.mats[1].m)
			node.scale = magic.Vector3(wield.EXTRUDED_SCALE,
					wield.EXTRUDED_SCALE, wield.EXTRUDED_SCALE)
		end
		cg.castShadows = false
		node.enabled = false
		h.shapes[name] = sh
		return sh
	end

	-- item: the wielded item's name or nil; draw: -1 not drawing, else 0
	-- to 1; arrow: whether an arrow is nocked; light {r, g, b} or nil
	function h:update(item, draw, arrow, light)
		for n, sh in pairs(h.shapes) do
			sh.node.enabled = n == item
		end
		local sh = item and shape(item)
		if not sh then
			return
		end
		sh.node.enabled = true
		if sh.bow and (draw ~= h.draw or arrow ~= h.arrow) then
			h.draw, h.arrow = draw, arrow
			build_bow(sh.cg, math.max(0, draw), arrow)
			for i, m in ipairs(sh.mats) do
				sh.cg:SetMaterial(i - 1, m.m)
			end
		end
		if sh.bow then
			-- Drawn, from the hand's place and turn up before the eye,
			-- aimed along the look, eased by the draw
			local e = draw > 0 and draw * draw * (3 - 2 * draw) or 0
			local function mix(a, b) return a + (b - a) * e end
			h.node.position = magic.Vector3(mix(base.x, 0.012),
					mix(base.y, -0.012), base.z)
			h.node.rotation = wield.REST:Slerp(magic.Quaternion(0, 0, -8), e)
			sh.node.scale = magic.Vector3(0.11, 0.11, 0.11)
		else
			h.node.position = magic.Vector3(base.x, base.y, base.z)
			h.node.rotation = wield.REST
		end
		if light and (light ~= h.light or item ~= h.item) then
			for _, m in ipairs(sh.mats) do
				m.m:SetShaderParameter("MatDiffColor", magic.Variant(magic.Color(
						m.colour[1] * light[1], m.colour[2] * light[2],
						m.colour[3] * light[3], 1)))
			end
		end
		h.light, h.item = light, item
	end
	return h
end

return M
-- vim: set noet ts=4 sw=4:
