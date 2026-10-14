-- Buildat: builtin/luanti/lua/test.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- Checks the parts of this module that are arithmetic rather than
-- arrangement: base64, ColorSpec, ItemStack, the inventory, the content id
-- allocator and the mod ordering. Wants no engine, so:
--
--   $ lua builtin/luanti/lua/test.lua
--
-- The rest is checked by loading a game: devtest's own unittests mod runs
-- while it loads and takes the server down if any of this is wrong, which is
-- the reason devtest is the fixture.

local dir = arg[0]:match("^(.*)/[^/]*$") or "."

core = {}
core.registered_items = {}
function core.log() end
function core.write_json(t) return "{}" end
function core.safe_file_write() return true end

dofile(dir .. "/classes.lua")
dofile(dir .. "/colorspec.lua")
dofile(dir .. "/misc.lua")
local modlist = dofile(dir .. "/modlist.lua")
dofile(dir .. "/objmesh.lua")
dofile(dir .. "/b3dmesh.lua")
dofile(dir .. "/json.lua")
dofile(dir .. "/gltfmesh.lua")
dofile(dir .. "/mesh.lua")

local function check(name, f)
	local ok, err = pcall(f)
	if not ok then
		io.stderr:write("luanti/test.lua: " .. name .. ": " .. tostring(err) ..
				"\n")
		os.exit(1)
	end
	print(name .. ": ok")
end

check("base64", function()
	local cases = {"", "a", "ab", "abc", "abcd",
			"Hello, Luanti!\0\1\255\254"}
	for _, s in ipairs(cases) do
		local encoded = core.encode_base64(s)
		assert(core.decode_base64(encoded) == s, "roundtrip of " .. #s)
		assert(#encoded % 4 == 0, "padded to four")
	end
	assert(core.encode_base64("abc") == "YWJj")
	assert(core.decode_base64("!!!") == nil, "not base64")
	assert(core.decode_base64(core.encode_base64("ab")) == "ab")
end)

check("node position hash", function()
	for _, p in ipairs({{x = 0, y = 0, z = 0}, {x = -5, y = 7, z = 1000},
			{x = 32767, y = -32768, z = 1}}) do
		local back = core.get_position_from_hash(core.hash_node_position(p))
		assert(back.x == p.x and back.y == p.y and back.z == p.z,
				"roundtrip of " .. p.x .. "," .. p.y .. "," .. p.z)
	end
end)

check("colorspec", function()
	assert(core.colorspec_to_colorstring("#abc") == "#AABBCCFF")
	assert(core.colorspec_to_colorstring("#ff8000") == "#FF8000FF")
	assert(core.colorspec_to_colorstring("#ff800080") == "#FF800080")
	assert(core.colorspec_to_colorstring("peachpuff") == "#FFDAB9FF")
	assert(core.colorspec_to_colorstring("white#7f") == "#FFFFFF7F")
	assert(core.colorspec_to_colorstring({r = 1, g = 2, b = 3}) == "#010203FF")
	assert(core.colorspec_to_colorstring("nosuchcolour") == nil)
	assert(#core.colorspec_to_bytes("black") == 4)
end)

check("itemstack", function()
	core.registered_items["test:thing"] = {description = "A thing",
			stack_max = 10}
	core.registered_items["test:tool"] = {description = "A tool",
			stack_max = 1}

	assert(ItemStack():is_empty())
	assert(ItemStack(""):is_empty())

	local s = ItemStack("test:thing 4")
	assert(s:get_name() == "test:thing" and s:get_count() == 4)
	assert(s:to_string() == "test:thing 4")
	-- The metadata field, Luanti's own form and the round trip
	local m = ItemStack("test:pick 1 21323 \"\1description\2My worn out pick\3\"")
	assert(m:get_wear() == 21323, m:get_wear())
	assert(m:get_meta():get_string("description") == "My worn out pick",
			m:get_meta():get_string("description"))
	assert(ItemStack(m:to_string()):get_meta():get_string("description") ==
			"My worn out pick", m:to_string())
	assert(ItemStack("test:book 1 0 \"plain desc\""):get_meta():get_string("description") ==
			"plain desc")
	local q = ItemStack("test:thing")
	q:get_meta():set_string("k", 'a "quoted" \\ value')
	assert(ItemStack(q:to_string()):get_meta():get_string("k") == 'a "quoted" \\ value',
			q:to_string())
	assert(s:get_stack_max() == 10 and s:get_free_space() == 6)
	assert(s:get_description() == "A thing")

	-- What does not fit comes back
	local left = s:add_item("test:thing 9")
	assert(s:get_count() == 10, "filled to the stack max")
	assert(left:get_count() == 3, "three left over")

	-- A different item does not merge
	local other = s:add_item("test:tool")
	assert(other:get_count() == 1 and s:get_count() == 10)

	local taken = s:take_item(4)
	assert(taken:get_count() == 4 and s:get_count() == 6)
	assert(s:peek_item(2):get_count() == 2 and s:get_count() == 6,
			"peek takes nothing")

	-- Emptying clears the name, as Luanti's does
	s:set_count(0)
	assert(s:is_empty() and s:get_name() == "" and s:to_string() == "")

	-- Metadata travels with a copy and is compared by value
	local a = ItemStack("test:tool")
	a:get_meta():set_string("owner", "nobody")
	local b = ItemStack(a)
	assert(b:get_meta():get_string("owner") == "nobody")
	assert(a:equals(b))
	b:get_meta():set_string("owner", "somebody")
	assert(not a:equals(b), "metadata is part of equality")

	-- Wear, and the uses a tool has
	local t = ItemStack("test:tool")
	t:add_wear_by_uses(10)
	assert(t:get_wear() == 6553, "one use of ten")

	-- A tool is used up after exactly the uses it has and not before,
	-- whatever the wear range does not divide evenly into: 130 is Luanti's
	-- own example of that
	local function uses_until_gone(uses)
		local s = ItemStack("test:tool")
		local n = 0
		while not s:is_empty() and n < 70000 do
			s:add_wear_by_uses(uses)
			n = n + 1
		end
		return n
	end
	assert(uses_until_gone(1) == 1, "a tool of one use")
	assert(uses_until_gone(10) == 10, "a tool of ten uses")
	assert(uses_until_gone(130) == 130, "a tool of a hundred and thirty")
	assert(core.get_tool_wear_after_use(130) == 504, "the API's name")
	assert(core.get_tool_wear_after_use(0) == 0, "infinite uses")
end)

check("inventory", function()
	core.registered_items["test:thing"] = {stack_max = 10}
	local inv = core.__new_inventory({type = "detached", name = "test"})
	inv:set_size("main", 3)
	assert(inv:get_size("main") == 3 and inv:is_empty("main"))

	assert(inv:room_for_item("main", "test:thing 30"))
	assert(not inv:room_for_item("main", "test:thing 31"))

	local left = inv:add_item("main", "test:thing 25")
	assert(left:is_empty(), "25 fits in three stacks of ten")
	assert(inv:get_stack("main", 1):get_count() == 10)
	assert(inv:get_stack("main", 3):get_count() == 5)
	assert(not inv:is_empty("main"))
	assert(inv:contains_item("main", "test:thing 25"))
	assert(not inv:contains_item("main", "test:thing 26"))

	local taken = inv:remove_item("main", "test:thing 7")
	assert(taken:get_count() == 7)
	assert(inv:contains_item("main", "test:thing 18"))

	-- A stack read out is a copy: writing to it does not write to the list
	local stack = inv:get_stack("main", 1)
	stack:set_count(1)
	assert(inv:get_stack("main", 1):get_count() == 10, "get_stack copies")

	assert(inv:get_location().name == "test")
end)

check("mod ordering", function()
	local function mod(name, depends, optional)
		return {name = name, path = "/" .. name,
				depends = modlist.split_list(depends),
				optional_depends = modlist.split_list(optional)}
	end
	local mods = {
		mod("last_mod"),
		mod("stairs", "basenodes"),
		mod("basenodes", "first_mod"),
		mod("first_mod"),
		mod("testnodes", "basenodes", "stairs"),
	}
	local order = modlist.order_mods(mods, "first_mod", "last_mod")
	local at = {}
	for i, m in ipairs(order) do
		at[m.name] = i
	end
	assert(#order == 5)
	assert(at.first_mod == 1, "first_mod is first")
	assert(at.last_mod == #order, "last_mod is last")
	assert(at.basenodes < at.stairs, "a dependency loads first")
	assert(at.stairs < at.testnodes, "an optional dependency loads first")

	-- A dependency that is not there is an error; an optional one is not
	assert(not pcall(modlist.order_mods, {mod("a", "nosuch")}))
	assert(pcall(modlist.order_mods, {mod("a", "", "nosuch")}))
	-- A cycle is an error rather than a hang
	assert(not pcall(modlist.order_mods, {mod("a", "b"), mod("b", "a")}))
end)

check("mod scan order", function()
	local function m(name, from_modpack)
		return {name = name, from_modpack = from_modpack or false}
	end
	-- Luanti sorts by name case-insensitively and puts every mod that came
	-- from a modpack before every one that did not
	local mods = {m("Zebra"), m("apple"), m("more_ore", true),
			m("mtg_default", true), m("banana")}
	modlist.sort_mods(mods)
	local names = {}
	for i, mod in ipairs(mods) do
		names[i] = mod.name
	end
	assert(table.concat(names, ",") ==
			"more_ore,mtg_default,apple,banana,Zebra",
			"the modpack's mods first, each half by name: " ..
			table.concat(names, ","))
end)

check("depends.txt parsing", function()
	local d, o = modlist.parse_depends_txt(
			"default\nbones\nwatershed?\n\n  highlandpools?  \n")
	assert(#d == 2 and d[1] == "default" and d[2] == "bones",
			"one mod a line")
	assert(#o == 2 and o[1] == "watershed" and o[2] == "highlandpools",
			"a trailing ? is optional, and the name keeps none of it")
	-- A game that ships neither file depends on nothing
	local e1, e2 = modlist.parse_depends_txt(nil)
	assert(#e1 == 0 and #e2 == 0)
end)

check("multi-line conf values", function()
	-- What scifi_nodes writes, and what a parser that reads only the first
	-- line sees instead: no dependencies at all
	local t = modlist.parse_conf(
			'name = scifi_nodes\n' ..
			'optional_depends = """\n' ..
			'default,\n' ..
			'xpanes,\n' ..
			'dye\n' ..
			'"""\n' ..
			'description = after the value\n')
	assert(t.name == "scifi_nodes", "a plain value beside a long one")
	assert(t.description == "after the value",
			"and the file carries on after the marker")
	local list = modlist.split_list(t.optional_depends)
	assert(#list == 3 and list[1] == "default" and list[2] == "xpanes" and
			list[3] == "dye",
			"the whole list is the value: " .. tostring(t.optional_depends))
	-- An indented marker is not the marker, which is Luanti's own rule
	local u = modlist.parse_conf('k = """\n  """\na\n"""\nafter = 1\n')
	assert(u.k == '  """\na', "only a bare marker ends the value")
	assert(u.after == "1")
end)

check("conf parsing", function()
	local t = modlist.parse_conf(
			"# a comment\nname = foo\ndepends = a, b ,c\n\nempty =\n")
	assert(t.name == "foo")
	assert(t.empty == "")
	local list = modlist.split_list(t.depends)
	assert(#list == 3 and list[1] == "a" and list[3] == "c")
end)

-- What the module reads out of a "mesh" node's model: the readers
-- themselves are checked in extensions/luanti_client/test.lua, where they
-- were written, so this is the flattening -- a quad is twenty-one numbers,
-- a material is the tile of the same number counted from zero, and
-- visual_scale multiplies every corner.
check("mesh quads", function()
	local flat, skipped = core.__mesh_quads("thing.obj", [[
v -0.5 -0.5 0.0
v 0.5 -0.5 0.0
v 0.5 0.5 0.0
v -0.5 0.5 0.0
vt 0.0 0.0
vt 1.0 0.0
vt 1.0 1.0
vt 0.0 1.0
usemtl first
f 1/1 2/2 3/3 4/4
usemtl second
f 1/1 2/2 3/3
f 1 2
]], 2)
	assert(#flat == 21 * 2, "two faces of twenty-one numbers, got " .. #flat)
	assert(skipped == 1, "a two-corner face is not a face")
	assert(flat[1] == 0, "the first material is tile zero")
	assert(flat[22] == 1, "the second material is tile one")
	assert(flat[2] == -1.0, "visual_scale multiplies a corner")
	assert(flat[14] == 0.0 and flat[15] == 1.0,
			"the texture coordinates follow the corners")
	-- A format nothing here reads leaves the node its cube
	assert(core.__mesh_quads("thing.x", "", 1) == nil)
	assert(core.__mesh_quads("thing.obj", "", 1) == nil)
end)

-- A bone's keys are mixed between frames ([OBJECT_ANIM_LOOK]): one
-- triangle on a bone whose position keys are 0 at frame 0 and 10 along x at
-- frame 10, in separate KEYS chunks from its rotation's, which stands.
-- Frame 5 is half way; past the last key the last.
check("b3d keys between frames", function()
	local function le32(v)
		v = v % 0x100000000
		return string.char(v % 256, math.floor(v / 256) % 256,
				math.floor(v / 0x10000) % 256, math.floor(v / 0x1000000))
	end
	local function lef32(v)
		if v == 0 then
			return string.char(0, 0, 0, 0)
		end
		local exp = 0
		while v >= 2 do v = v / 2; exp = exp + 1 end
		while v < 1 do v = v * 2; exp = exp - 1 end
		local mant = math.floor((v - 1) * 0x800000 + 0.5)
		local e = exp + 127
		return string.char(mant % 256, math.floor(mant / 0x100) % 256,
				(e % 2) * 128 + math.floor(mant / 0x10000), math.floor(e / 2))
	end
	local function chunk(tag, body)
		return tag .. le32(#body) .. body
	end
	local function f(...)
		local out = ""
		for _, v in ipairs({...}) do out = out .. lef32(v) end
		return out
	end
	local vrts = chunk("VRTS", le32(0) .. le32(1) .. le32(2) ..
			f(0, 0, 0, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1))
	local tris = chunk("TRIS", le32(0) .. le32(0) .. le32(1) .. le32(2))
	local mesh = chunk("MESH", le32(0xffffffff) .. vrts .. tris)
	local bone = chunk("BONE", le32(0) .. f(1) .. le32(1) .. f(1) ..
			le32(2) .. f(1))
	local pos = chunk("KEYS", le32(1) .. le32(0) .. f(0, 0, 0) ..
			le32(10) .. f(10, 0, 0))
	local rot = chunk("KEYS", le32(4) .. le32(0) .. f(1, 0, 0, 0) ..
			le32(10) .. f(1, 0, 0, 0))
	local node = chunk("NODE", "root\0" .. f(0, 0, 0, 1, 1, 1, 1, 0, 0, 0) ..
			mesh .. bone .. pos .. rot)
	local body = le32(1) .. node
	local b3d = "BB3D" .. le32(#body + 4) .. body
	local function x_at(frame)
		return core.__b3dmesh.parse(b3d, frame)[1].p[1]
	end
	assert(x_at(nil) == 0, "the bind pose")
	assert(math.abs(x_at(5) - 5) < 1e-6, "frame 5 is " .. x_at(5))
	assert(math.abs(x_at(2) - 2) < 1e-6, "frame 2 is " .. x_at(2))
	assert(math.abs(x_at(20) - 10) < 1e-6, "past the last key")
end)

check("gltf mesh", function()
	-- One triangle at (0,0,0), (1,0,0), (0,1,0) with its texture
	-- coordinates, in a node scaled by two: the buffer is the indices, the
	-- three positions and the three pairs, in that order
	local BUFFER = "AAABAAIAAAAAAAAAAAAAAAAAAAAAAIA/AAAAAAAAAAAAAAAAAACAPw" ..
			"AAAAAAAAAAAAAAAAAAgD8AAAAAAAAAAAAAgD8="
	local function document(uri)
		return '{"asset":{"version":"2.0"},"scene":0,' ..
			'"scenes":[{"nodes":[0]}],"nodes":[{"mesh":0,"scale":[2,2,2]}],' ..
			'"meshes":[{"primitives":[{"attributes":{"POSITION":1,' ..
			'"TEXCOORD_0":2},"indices":0,"material":0}]}],"materials":[{}],' ..
			'"buffers":[{"byteLength":68' ..
			(uri and (',"uri":"data:application/octet-stream;base64,' ..
				BUFFER .. '"') or "") .. '}],' ..
			'"bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":6},' ..
			'{"buffer":0,"byteOffset":8,"byteLength":36},' ..
			'{"buffer":0,"byteOffset":44,"byteLength":24}],' ..
			'"accessors":[{"bufferView":0,"componentType":5123,"count":3,' ..
			'"type":"SCALAR"},{"bufferView":1,"componentType":5126,' ..
			'"count":3,"type":"VEC3"},{"bufferView":2,"componentType":5126,' ..
			'"count":3,"type":"VEC2"}]}'
	end

	local flat, skipped = core.__mesh_quads("thing.gltf", document(true), 1)
	assert(flat ~= nil, "the document was not read")
	assert(#flat == 21, "one triangle is one quad, got " .. #flat)
	assert(skipped == 0, "nothing was skipped")
	assert(flat[1] == 0, "the first material is tile zero")
	-- The corners: the node's scale of two is applied and glTF's handedness
	-- is undone, which is what negates x
	assert(flat[2] == 0 and flat[3] == 0 and flat[4] == 0, "the first corner")
	assert(flat[5] == 0 and flat[6] == 2 and flat[7] == 0,
			"the winding turns over with the handedness")
	assert(flat[8] == -2 and flat[9] == 0 and flat[10] == 0,
			"x is negated and the scale is applied")
	assert(flat[11] == -2 and flat[12] == 0 and flat[13] == 0,
			"a triangle is a quad with its last corner twice")
	assert(flat[14] == 0 and flat[15] == 0, "the first pair")
	assert(flat[16] == 0 and flat[17] == 1, "the second corner's pair")

	-- The same document as a .glb: the JSON in one chunk and the buffer in
	-- the next, which is what an exporter writes as a single file
	local function u32(v)
		return string.char(v % 256, math.floor(v / 256) % 256,
				math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
	end
	local json = document(false)
	json = json .. string.rep(" ", (4 - #json % 4) % 4)
	local bin = core.decode_base64(BUFFER)
	bin = bin .. string.rep("\0", (4 - #bin % 4) % 4)
	local glb = "glTF" .. u32(2) .. u32(12 + 8 + #json + 8 + #bin) ..
			u32(#json) .. "JSON" .. json .. u32(#bin) .. "BIN\0" .. bin
	local flat2 = core.__mesh_quads("thing.glb", glb, 1)
	assert(flat2 ~= nil, "the glb was not read")
	assert(#flat2 == #flat, "the same triangle, got " .. #flat2)
	for i = 1, #flat do
		assert(flat2[i] == flat[i], "the glb differs at " .. i)
	end
end)

print("builtin/luanti/lua/test.lua: ok")

-- vim: set noet ts=4 sw=4:
