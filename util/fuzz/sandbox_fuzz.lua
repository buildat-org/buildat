-- SPDX-License-Identifier: Apache-2.0 OR MIT
-- [SECURITY_RUN_1] phase 4: what a server's Lua can do to the client
-- through the sandbox's own API. client_fuzz.py sends this as
-- core:run_script with SEED set in front of it; it walks buildat and the
-- extensions' safe tables for functions and calls them with values at
-- the edges and with whatever earlier calls returned (objects, as a
-- method's self), each in a pcall: a Lua error is the API refusing, which
-- is fine, and only a crash or a hang is a finding. Each call is logged
-- before it is made, so the last "sandbox_fuzz:" line names a crash.
-- extensions/sandbox_test is the other half: whether a script can reach
-- past the verbs at all, by a fixed list of attempts.
local log = buildat.Logger("sandbox_fuzz")
local rnd_state = SEED or 1
local function rnd(n)
	rnd_state = (rnd_state * 1103515245 + 12345) % 2147483648
	return math.floor(rnd_state / 65536) % n + 1
end

-- What ends the run is not a finding, and neither is Lua of the
-- client's own that takes as long as it is asked to: dump walks a cyclic
-- table until the stack runs out, which a server's own loop can do anyway
-- (no instruction limit on a served chunk; the run's open question)
local skip = {"quit", "exit", "disconnect", "leave", "sleep", "reset_sandbox",
		"run_script", "connect", "dump"}
local function skipped(path)
	local p = string.lower(path)
	for _, s in ipairs(skip) do
		if string.find(p, s, 1, true) then return true end
	end
	return false
end

local funcs = {}
local seen = {}
-- Tables met on the walk -- inside a game, its scene, nodes and UI
-- among them -- are the calls' material as well as what calls return
-- (the sandbox has no getmetatable to tell an object from a table)
local found = {}
local function walk(t, path, depth)
	if depth > 3 or seen[t] then return end
	seen[t] = true
	-- A table that will not be walked (a view's own refusal) is skipped
	pcall(function()
		for k, v in pairs(t) do
			local p = path.."."..tostring(k)
			if type(v) == "function" then
				if not skipped(p) then
					table.insert(funcs, {p, v})
				end
			elseif type(v) == "table" then
				if #found < 50 then
					table.insert(found, v)
				end
				walk(v, p, depth + 1)
			end
		end
	end)
end
walk(buildat, "buildat", 1)
-- A module is there when a game serves it (game_fuzz.sh); elsewhere its
-- require fails, which the pcall takes
for _, name in ipairs({"extension/urho3d", "extension/magic_sandbox",
		"extension/network", "extension/replicate", "extension/starport",
		"extension/uistack", "extension/sandbox_scan", "extension/cereal",
		"extension/physical_sky", "extension/ui_utils", "extension/luanti_client",
		"module/luanti", "module/voxelworld", "module/voxel_shading"}) do
	local ok, m = pcall(require, "buildat/"..name)
	if ok and type(m) == "table" then walk(m, (name:gsub(".*/", "")), 1) end
end

local pool = {nil, true, false, 0, -1, 1, 0.5, 255, 65536, 2^31, -2^31,
		2^32 + 1, 2^53, -2^53, 1e308, -1e308, 0/0, 1/0, -1/0, "", "a",
		"../../../etc/passwd", "a\0b", "%s%s%n", string.rep("A", 70000),
		"http://127.0.0.1:1/", "file:///etc/passwd", "Textures/x.png",
		{}, {1, 2, 3}, {x = 1e308, y = 0/0}, function() end}
local npool = #pool
for _, v in ipairs(found) do
	npool = npool + 1
	pool[npool] = v
end
-- Where a value in the pool came from, for the log (the sandbox has no
-- setmetatable)
local rindex = {}
local function value()
	return pool[rnd(npool)]
end

log:info("sandbox_fuzz: "..#funcs.." functions, "..#found..
		" tables found, seed "..rnd_state)
for i = 1, 400 do
	if #funcs == 0 then break end
	local f = funcs[rnd(#funcs)]
	local args = {}
	local n = rnd(5) - 1
	for j = 1, n do args[j] = value() end
	local shown = {}
	for j = 1, n do
		local v = args[j]
		shown[j] = type(v) == "string" and string.format("%q", v:sub(1, 20)) or
				type(v) == "number" and tostring(v) or
				type(v)..":"..(rindex[v] or "pool")
	end
	log:info("sandbox_fuzz: "..f[1].."("..table.concat(shown, ", ")..")")
	local ok, r = pcall(f[2], unpack(args, 1, n))
	-- What came back is the next calls' material: objects, as self
	if ok and r ~= nil and npool < 200 then
		npool = npool + 1
		pool[npool] = r
		-- Not a number's: a NaN is no table key, and the log shows numbers
		if type(r) ~= "number" then rindex[r] = rindex[r] or f[1] end
	end
end
log:info("sandbox_fuzz: done")
