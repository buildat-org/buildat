-- Buildat: apps/skeldat/main/client_lua/wield.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- **What the hand holds, and where** ([SKELDAT_BOW]): an item's picture
-- extruded into a slab, a node's cube, and official Luanti's place and
-- turn for them in front of the camera -- as builtin/luanti's client draws
-- them ([WIELD_MESH]), skeldat's own copy (user, 2026-10-17: skeldat
-- shares no wield, HUD or UI code with luanti_client).
local magic = require("buildat/extension/urho3d")
local M = {}

-- The face's normal, for a lit technique; the second winding's is the
-- other way
local function normal(a, b, c)
	local ux, uy, uz = b[1] - a[1], b[2] - a[2], b[3] - a[3]
	local vx, vy, vz = c[1] - a[1], c[2] - a[2], c[3] - a[3]
	local nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz,
			ux * vy - uy * vx
	local l = math.sqrt(nx * nx + ny * ny + nz * nz)
	l = l > 0 and l or 1
	nx, ny, nz = nx / l, ny / l, nz / l
	return magic.Vector3(nx, ny, nz), magic.Vector3(-nx, -ny, -nz)
end

-- The picture img extruded into cg's geometry 0 (official's
-- WieldMeshSceneNode::setItem): a front and a back quad per opaque pixel
-- and an edge quad wherever an opaque pixel borders a transparent one,
-- each quad's texture coordinates at that pixel's centre, both windings
-- (a shape in the hand is looked at from whatever side the hand turns
-- to). A unit across; the caller scales it.
function M.extrude(cg, img)
	local function quad(a, b, c, d, u, v)
		local n, back = normal(a, b, c)
		for i, p in ipairs({a, b, c, a, c, d, a, c, b, a, d, c}) do
			cg:DefineVertex(magic.Vector3(p[1], p[2], p[3]))
			cg:DefineNormal(i <= 6 and n or back)
			cg:DefineTexCoord(magic.Vector2(u, v))
		end
	end
	local w, h = img.width, img.height
	local function opaque(x, y)
		if x < 0 or y < 0 or x >= w or y >= h then
			return false
		end
		return img:GetPixel(x, y).a > 0.5
	end
	cg:SetNumGeometries(1)
	cg:BeginGeometry(0, magic.TRIANGLE_LIST)
	local t = 0.5 / w
	for y = 0, h - 1 do
		for x = 0, w - 1 do
			if opaque(x, y) then
				local u, v = (x + 0.5) / w, (y + 0.5) / h
				local x0, x1 = (x - w / 2) / w, (x + 1 - w / 2) / w
				local y0, y1 = (h / 2 - y - 1) / h, (h / 2 - y) / h
				quad({x0, y1, -t}, {x1, y1, -t}, {x1, y0, -t}, {x0, y0, -t}, u, v)
				quad({x0, y1, t}, {x0, y0, t}, {x1, y0, t}, {x1, y1, t}, u, v)
				if not opaque(x - 1, y) then
					quad({x0, y1, -t}, {x0, y0, -t}, {x0, y0, t}, {x0, y1, t}, u, v)
				end
				if not opaque(x + 1, y) then
					quad({x1, y1, t}, {x1, y0, t}, {x1, y0, -t}, {x1, y1, -t}, u, v)
				end
				if not opaque(x, y - 1) then
					quad({x0, y1, t}, {x1, y1, t}, {x1, y1, -t}, {x0, y1, -t}, u, v)
				end
				if not opaque(x, y + 1) then
					quad({x0, y0, -t}, {x1, y0, -t}, {x1, y0, t}, {x0, y0, t}, u, v)
				end
			end
		end
	end
	cg:Commit()
end

-- A unit cube into cg: the top and bottom on geometry 0, the +/-x sides on
-- 1, the +/-z on 2, so a node's top and side tiles go on as three
-- materials
function M.cube(cg)
	cg:SetNumGeometries(3)
	local h = 0.5
	local function uvface(a, b, c, d)
		local uv = {{0, 0}, {1, 0}, {1, 1}, {0, 1}}
		local ps = {a, b, c, d}
		local n, back = normal(a, b, c)
		for k, i in ipairs({1, 2, 3, 1, 3, 4, 1, 3, 2, 1, 4, 3}) do
			cg:DefineVertex(magic.Vector3(ps[i][1], ps[i][2], ps[i][3]))
			cg:DefineNormal(k <= 6 and n or back)
			cg:DefineTexCoord(magic.Vector2(uv[i][1], uv[i][2]))
		end
	end
	cg:BeginGeometry(0, magic.TRIANGLE_LIST)
	uvface({-h, h, -h}, {h, h, -h}, {h, h, h}, {-h, h, h})
	uvface({-h, -h, h}, {h, -h, h}, {h, -h, -h}, {-h, -h, -h})
	cg:BeginGeometry(1, magic.TRIANGLE_LIST)
	uvface({h, h, -h}, {h, h, h}, {h, -h, h}, {h, -h, -h})
	uvface({-h, h, h}, {-h, h, -h}, {-h, -h, -h}, {-h, -h, h})
	cg:BeginGeometry(2, magic.TRIANGLE_LIST)
	uvface({-h, h, -h}, {-h, -h, -h}, {h, -h, -h}, {h, h, -h})
	uvface({h, h, h}, {h, -h, h}, {-h, -h, h}, {-h, h, h})
	cg:Commit()
end

-- Where a hand is: official's numbers ([WIELD_MESH] 4, camera.cpp
-- drawWieldedTool and wieldmesh.cpp), read off the code: the wield scene's
-- camera is at the origin looking down +Z at FOV 72, the mesh rests at
-- (55, -35, 65) Irrlicht units (BS 10 to the node; the tool-change
-- timer sits at 0.125 at rest, so its `|timer| * 320 - 40` is nought
-- and not -40), turned by the Euler (-100, 120, -100) taken X then Y then
-- Z about the fixed axes (Irrlicht's setRotationDegrees), an extruded item
-- scaled by wield_scale * 40, a node by wield_scale * 30 / BS.
--
-- Luanti draws it in a scene of its own with the depth cleared. Here it is
-- a child of the camera node in the world's scene, so it has to sit inside
-- the world's near plane (a tenth of a node) and nearer than the player's
-- own box is wide, so that no wall comes between it and the eye: the whole
-- thing is divided by SHRINK, position and size together, which is the
-- same picture from a camera at the origin.
M.SHRINK = 26
M.EXTRUDED_SCALE = 40 / 10 / M.SHRINK
M.NODE_SCALE = 30 / 10 / M.SHRINK
-- The resting place for a camera of fov degrees (a wider or narrower view
-- than official's 72 keeps the hand at its place on the screen): the
-- position, the rotation and the scale, set on node; the position also
-- returned
function M.place(node, fov)
	local k = math.tan(math.rad(fov / 2)) / math.tan(math.rad(36))
	local base = {x = 5.5 / M.SHRINK * k, y = -3.5 / M.SHRINK * k,
			z = 6.5 / M.SHRINK}
	node.position = magic.Vector3(base.x, base.y, base.z)
	node.rotation = M.REST
	node.scale = magic.Vector3(k, k, k)
	return base
end
M.REST = magic.Quaternion(-100, magic.Vector3(0, 0, 1)) *
		magic.Quaternion(120, magic.Vector3(0, 1, 0)) *
		magic.Quaternion(-100, magic.Vector3(1, 0, 0))

return M
