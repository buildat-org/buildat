-- Buildat: sample_wasm/client_lua/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- [CLIENT_WASM] The module's wasm/ loaded and called: numbers both ways,
-- a buffer written, changed by the module and read back, and the traps;
-- then the imports (step 2): a mesh and a texture from its memory, a node
-- moved, a voxel volume read, a packet to the server and its answer back
-- as an event, and the boundary refusing what it must; and the meter
-- (step 3) stopping calls and a start function that never end.
-- apps/sample_wasm/check.sh reads the lines this logs.
local log = buildat.Logger("sample_wasm")
local magic = require("buildat/extension/urho3d")

-- A malformed and an oversized .wasm, and one exporting the meter's name,
-- refused before anything runs
for _, name in ipairs({"malformed", "oversized", "meter_name"}) do
	local bad, why = buildat.wasm_load(name)
	assert(not bad, name.." was loaded")
	log:info(name.." refused: "..tostring(why))
end

local m, why = buildat.wasm_load("main")
assert(m, why)
-- Step 4: natively with a compile under way, it is ready at once in the
-- interpreter; state put in it now is still there once it has moved to the
-- compiled module (checked below)
local first_status, first_engine = m:status()
log:info("main loaded: "..tostring(first_status)..", "..tostring(first_engine))
local moving = first_engine == "interpreter, compiling"
if moving then
	m:write(m:call("buffer") + 2048, "kept across the move")
	assert(m:call("tick") == 1 and m:call("tick") == 2, "tick")
end
-- A second instance of it, whose handles the first must refuse; loaded in
-- the same frame, so that natively it waits on the first one's compile
-- ([WASM_COMPILE_RACE])
local m2 = buildat.wasm_load("main")
assert(m2)
-- Two more, each to be stopped by the meter in a call that never ends
local m3 = assert(buildat.wasm_load("main"))
local m4 = assert(buildat.wasm_load("main"))
-- A start function that never ends: stopped as it loads
local endless_start = assert(buildat.wasm_load("endless_start"))

local scene = magic.Scene()
scene:CreateComponent("Octree")
local mesh_node = scene:CreateChild("Mesh")
local cg = mesh_node:CreateComponent("CustomGeometry")
local tex = magic.Texture2D:new()
do
	local mat = magic.Material:new()
	mat:SetTechnique(0, magic.cache:GetResource("Technique",
			"Techniques/DiffUnlit.xml"))
	mat:SetTexture(magic.TU_DIFFUSE, tex)
	cg:SetMaterial(0, mat)
	local camera_node = scene:CreateChild("Camera")
	camera_node.position = magic.Vector3(2, 0.5, -3)
	local camera = camera_node:CreateComponent("Camera")
	magic.set_preferred_viewports({magic.Viewport:new(scene, camera)})
end

local function near(a, b)
	return math.abs(a - b) < 1e-4
end

local function box_is(what, x0, y0, z0, x1, y1, z1)
	local bb = cg.worldBoundingBox
	local ok = near(bb.min.x, x0) and near(bb.min.y, y0) and
			near(bb.min.z, z0) and near(bb.max.x, x1) and
			near(bb.max.y, y1) and near(bb.max.z, z1)
	assert(ok, what..": the mesh's box is "..bb.min.x..","..bb.min.y..","..
			bb.min.z.." to "..bb.max.x..","..bb.max.y..","..bb.max.z)
end

-- A call that has to trap; its error logged for check.sh
local function traps(what, ...)
	local ok, err = pcall(m.call, m, ...)
	assert(not ok, what.." did not trap")
	log:info(what..": "..tostring(err))
end

local function check()
	assert(m:call("add", 2, 3) == 5, "add")
	assert(m:call("add", 2147483647, 1) == -2147483648, "add wraps")
	local x = m:call("mix", 1.5, 0.25, 1000000)
	assert(x == 1000003.25, "mix: "..tostring(x))
	local p = m:call("buffer")
	m:write(p, "hello wasm")
	local sum = m:call("reverse", 10)
	assert(m:read(p, 10) == "msaw olleh", "the buffer reversed")
	log:info("add(2, 3) = "..m:call("add", 2, 3)..", reverse checksum "..sum)
	m:call("flood", 150)
	-- Lua's own mistakes, refused before the module sees them
	assert(not pcall(m.call, m, "add", 1), "too few numbers")
	assert(not pcall(m.call, m, "add", 1.5, 2), "a fraction for an i32")
	assert(not pcall(m.call, m, "nope"), "no such export")
	assert(not pcall(m.read, m, 2^31, 4), "a read past its memory")
	assert(not pcall(m.handle, m, "a string"), "a handle of a string")
	-- The module's, traps, after which it still answers
	local ok, err = pcall(m.call, m, "recurse", 0)
	assert(not ok, "the endless recursion trapped")
	log:info("recursion trap at depth "..m:call("depth")..": "..tostring(err))
	ok, err = pcall(m.call, m, "peek", 4294967292)
	assert(not ok, "the read past the memory trapped")
	log:info("memory trap: "..tostring(err))
	assert(m:call("add", 40, 2) == 42, "callable after the traps")
	-- A luaL_error() inside a guarded binding; check.sh reads its message
	-- natively and on the web ([GUARDED_LUA_ERROR], [WEB_LUA_ERROR_EH])
	ok, err = pcall(buildat.decompress, "x", "nope")
	assert(not ok, "an unknown format")
	log:info("guarded luaL_error: "..tostring(err))

	-- Step 2: a mesh and a texture from the module's memory
	local hn = m:handle(mesh_node)
	local ht = m:handle(tex)
	m:call("draw", hn, ht)
	box_is("drawn", 0, 0, 0, 1, 1, 0)
	assert(tex.width == 2 and tex.height == 2, "the texture's size")
	-- The node moved and turned by the module
	assert(m:call("move", hn, 2.5) == 2500, "move")
	assert(near(mesh_node.position.x, 2.5), "the node's x")
	box_is("moved", 1.5, 0, 0, 2.5, 1, 0)
	log:info("wasm drew a mesh and moved its node")
	-- A voxel volume, read whole
	local vol = buildat.Volume(buildat.Region(0, 0, 0, 3, 3, 3))
	local want_count, want_sum = 0, 0
	for _, v in ipairs({{1, 0, 0, 5}, {2, 3, 1, 7}, {3, 3, 3, 9}}) do
		vol:set_voxel_at(v[1], v[2], v[3], buildat.VoxelInstance(v[4]))
		want_count = want_count + 1
		want_sum = want_sum + v[4] * (v[1] + v[2] * 4 + v[3] * 16 + 1)
	end
	local hv = m:handle(vol)
	local got = m:call("voxels", hv)
	assert(got == want_count * 1000000 + want_sum, "voxels: "..got)
	log:info("wasm read the voxels: "..got)
	assert(m:call("now") >= 0, "time")

	-- The boundary: each of these traps in the import, with a log line
	local h2 = m2:handle(mesh_node)
	traps("another module's handle", "use_node", h2)
	traps("a forged handle", "use_node", hn + 1024)
	traps("a made-up handle", "use_node", 12345)
	local other = scene:CreateChild("Other")
	local hs = m:handle(other)
	m:call("use_node", hs)
	m:drop(hs)
	traps("a stale handle", "use_node", hs)
	assert(not pcall(m.drop, m, hs), "dropped twice")
	traps("a volume as a node", "use_node", hv)
	traps("a pointer past the memory", "bad_pointer", hn)
	traps("a pointer and length that wrap", "len_overflow")
	traps("an index past the vertices", "bad_index", hn)
	traps("a texture past the cap", "big_texture", ht)
	box_is("after the traps", 1.5, 0, 0, 2.5, 1, 0)
	assert(m:call("add", 40, 2) == 42, "callable after the import traps")

	-- Step 3, the meter: the hot loop's time, then a call that never ends
	-- on each of three instances, each stopped, and the first still
	-- answering
	-- (fewer in the interpreter, whose budget is a sixteenth: about as
	-- long in time)
	local rounds = select(2, m:status()) == "interpreter" and 4000 or 20000
	log:info("bench: the buffer reversed "..rounds.." times in "..
			m:call("bench", rounds).." ms")
	for _, c in ipairs({{m2, "spin"}, {m3, "spin_fill"}, {m4, "spin_tree", 60}}) do
		local t0 = m:call("now")
		local ok, err
		if c[3] then
			ok, err = pcall(c[1].call, c[1], c[2], c[3])
		else
			ok, err = pcall(c[1].call, c[1], c[2])
		end
		assert(not ok, c[2].." returned")
		local status, why = c[1]:status()
		assert(status == "failed" and why:find("past its budget"),
				c[2]..": "..tostring(status)..", "..tostring(why))
		assert(not pcall(c[1].call, c[1], "add", 1, 2), "called once stopped")
		log:info(c[2].." stopped after "..(m:call("now") - t0).." ms: "..
				tostring(err))
	end
	assert(m:call("add", 40, 2) == 42, "the first callable after the stops")
	local status, why = endless_start:status()
	assert(status == "failed" and why:find("start function ran past its budget"),
			"endless_start: "..tostring(status)..", "..tostring(why))
	log:info("endless_start: "..why)

	-- A packet to the server; its answer comes back as an event
	buildat.sub_packet("main:pong", function(data)
		m:push(data)
	end)
	assert(m:call("poll") == -1, "no event yet")
	m:call("ping")
end

-- Natively the first load compiles in the background
local stage = "loading"
local frame_after = false
magic.SubscribeToEvent("Update", function()
	if stage == "done" then return end
	if stage == "pong" then
		if not frame_after then
			frame_after = true
			log:info("a frame after the stops")
		end
		local n = m:call("poll")
		if n > 0 then
			stage = "done"
			log:info("wasm got the server's answer, "..n.." bytes")
			log:info("wasm done: ok")
		end
		return
	end
	-- Each ready, and natively in the engine it stays in: compiled, or
	-- the interpreter with no compiler (step 4)
	local engine
	for i, one in ipairs({m, m2, m3, m4}) do
		local status, detail = one:status()
		if status == "loading" or detail == "interpreter, compiling" then
			return
		end
		if status ~= "ready" then
			stage = "done"
			log:error("wasm done: load "..i.." failed: "..tostring(detail))
			return
		end
		engine = engine or detail
		if detail ~= engine then
			stage = "done"
			log:error("wasm done: engines "..engine.." and "..detail)
			return
		end
	end
	if endless_start:status() == "loading" then return end
	log:info("engine: "..engine)
	if moving then
		local kept = m:read(m:call("buffer") + 2048, 20)
		local ticks = m:call("tick")
		if engine ~= "compiled" or kept ~= "kept across the move" or
				ticks ~= 3 then
			stage = "done"
			log:error("wasm done: the move lost the state: "..engine..", "..
					kept..", "..ticks)
			return
		end
		log:info("the state moved with the module: "..kept..", tick "..ticks)
	end
	local ok, e = pcall(check)
	if not ok then
		stage = "done"
		log:error("wasm done: the check failed: "..tostring(e))
		return
	end
	stage = "pong"
end)
