-- SPDX-License-Identifier: Apache-2.0 OR MIT
-- core.get_node_boxes() against Luanti's own rotations, without a world:
-- the function's span is cut out of lua/stubs.lua (between its BEGIN
-- and END marks) and run over a few made-up nodes.
--
--   lua builtin/luanti/test/node_boxes.lua
local dir = arg[0]:match("^(.*)/[^/]*$") or "."
local f = assert(io.open(dir .. "/../lua/stubs.lua"))
local src = f:read("*a")
f:close()
local span = src:match("%-%- BEGIN get_node_boxes.-\n(.-)%-%- END get_node_boxes")
assert(span, "the BEGIN/END get_node_boxes marks are gone from stubs.lua")

core = {}
core.registered_nodes = {
	["t:stair"] = {drawtype = "nodebox", paramtype2 = "facedir",
		node_box = {type = "fixed", fixed = {{-0.5, -0.5, -0.5, 0.5, 0, 0.5}, {-0.5, 0, 0, 0.5, 0.5, 0.5}}}},
	["t:torch"] = {drawtype = "nodebox", paramtype2 = "wallmounted",
		node_box = {type = "wallmounted", wall_top = {-0.1, 0, -0.1, 0.1, 0.5, 0.1},
			wall_bottom = {-0.1, -0.5, -0.1, 0.1, 0, 0.1}, wall_side = {-0.5, -0.3, -0.1, -0.3, 0.3, 0.1}}},
	["t:stone"] = {drawtype = "normal"},
	["t:fence"] = {drawtype = "nodebox", connects_to = {"group:fence"}, groups = {fence = 1},
		node_box = {type = "connected", fixed = {-0.125, -0.5, -0.125, 0.125, 0.5, 0.125},
			connect_right = {0.125, 0, 0, 0.5, 0.2, 0.1}, connect_left = {-0.5, 0, 0, -0.125, 0.2, 0.1}}},
}
local world = {}
function core.get_node(p)
	return world[p.x .. "," .. p.y .. "," .. p.z] or {name = "air", param2 = 0}
end
assert(loadstring or load)(span, "get_node_boxes")()

local function eq(a, b)
	for i = 1, 6 do
		if math.abs(a[i] - b[i]) > 1e-9 then return false end
	end
	return true
end
local p = {x = 0, y = 0, z = 0}
-- A stair's upper half turned as Luanti's transformNodeBox turns it:
-- facedir 1 is rotateXZBy(-90), (x, z) -> (z, -x)
local s0 = core.get_node_boxes("node_box", p, {name = "t:stair", param2 = 0})
assert(#s0 == 2 and eq(s0[2], {-0.5, 0, 0, 0.5, 0.5, 0.5}))
local s1 = core.get_node_boxes("collision_box", p, {name = "t:stair", param2 = 1})
assert(eq(s1[2], {0, 0, -0.5, 0.5, 0.5, 0.5}), table.concat(s1[2], ","))
local s2 = core.get_node_boxes("node_box", p, {name = "t:stair", param2 = 2})
assert(eq(s2[2], {-0.5, 0, -0.5, 0.5, 0.5, 0}), table.concat(s2[2], ","))
-- A torch on the floor, and on the +x wall (the side box turned 180)
assert(eq(core.get_node_boxes("node_box", p, {name = "t:torch", param2 = 1})[1],
		{-0.1, -0.5, -0.1, 0.1, 0, 0.1}))
local t2 = core.get_node_boxes("node_box", p, {name = "t:torch", param2 = 2})[1]
assert(eq(t2, {0.3, -0.3, -0.1, 0.5, 0.3, 0.1}), table.concat(t2, ","))
-- A plain node is the cube, whatever box is asked for
assert(eq(core.get_node_boxes("selection_box", p, {name = "t:stone"})[1],
		{-0.5, -0.5, -0.5, 0.5, 0.5, 0.5}))
-- A fence reaches the fence beside it and not the air
world["1,0,0"] = {name = "t:fence", param2 = 0}
local fb = core.get_node_boxes("node_box", p, {name = "t:fence", param2 = 0})
assert(#fb == 2 and eq(fb[2], {0.125, 0, 0, 0.5, 0.2, 0.1}), #fb)
print("get_node_boxes: ok")

-- core.raycast() goes by the selection boxes ([VL_RAIL_BOXES]): a ray over
-- a rail's plate points at the stone behind it, one down onto the plate at
-- the rail with the node above as its above
core.registered_nodes["t:rail"] = {drawtype = "mesh",
	selection_box = {type = "fixed", fixed = {-0.5, -0.5, -0.5, 0.5, -0.5 + 1/16, 0.5}}}
core.registered_nodes.air = {drawtype = "airlike", pointable = false}
world = {["0,0,0"] = {name = "t:rail", param2 = 0}, ["0,0,1"] = {name = "t:stone", param2 = 0}}
vector = {new = function(a, b, c)
	if type(a) == "table" then return {x = a.x, y = a.y, z = a.z} end
	return {x = a, y = b, z = c}
end}
function core.get_objects_inside_radius() return {} end
dofile(dir .. "/../lua/raycast.lua")
local function first(p1, p2)
	for hit in core.raycast(p1, p2, false, false) do
		return hit
	end
end
local h = first({x = 0, y = 0, z = -2}, {x = 0, y = 0, z = 3})
assert(h and h.under.z == 1 and h.above.z == 0, "the ray over the rail: " .. (h and h.under.x..","..h.under.y..","..h.under.z or "nil"))
h = first({x = 0.1, y = 2, z = 0.1}, {x = 0.1, y = -2, z = 0.1})
assert(h and h.under.z == 0 and h.under.y == 0 and h.above.y == 1 and
		math.abs(h.intersection_point.y - (-0.5 + 1/16)) < 1e-6, "the ray down")
-- From the side, low enough to meet the plate: the rail, above the node
-- the ray came from
h = first({x = 0, y = -0.47, z = -2}, {x = 0, y = -0.47, z = 3})
assert(h and h.under.z == 0 and h.above.z == -1, "the ray along the plate")
print("raycast: ok")
