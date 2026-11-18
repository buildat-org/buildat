-- extensions/weave/test/gen_test.lua: weave1's generator in plain Lua (no
-- client): luajit extensions/weave/test/gen_test.lua (from the tree's root;
-- any Lua 5.1 or later gives the same hashes)
--   - each preset's pixels hash as weave1 was made with (self_check);
--   - the noise tiles at every size: a seam across the tile's edge is no
--     worse than the worst line between two of its own rows or columns, by a
--     tenth (a
--     pattern's elements and gaps tile by construction: every coordinate
--     is taken modulo the tile, and an element's edge may well fall on the
--     tile's, which a seam test cannot tell from a seam);
--   - the compact form, the table form and the resource name read back.
local G = dofile("extensions/weave/weave_gen.lua")
local bad = 0
local function fail(s)
	print("FAIL: " .. s)
	bad = bad + 1
end

local ok, why = G.self_check()
if not ok then
	for _, w in ipairs(why) do
		fail(w)
	end
end

-- The sum of the differences between two lines of pixels: rows (dy) or
-- columns
local function line_diff(px, a, b, rows)
	local n, s, d = px.size, px.rgba, 0
	for i = 0, n - 1 do
		local p = rows and (a * n + i) or (i * n + a)
		local q = rows and (b * n + i) or (i * n + b)
		for c = 1, 3 do
			d = d + math.abs(s:byte(p * 4 + c) - s:byte(q * 4 + c))
		end
	end
	return d
end
local function seamless(px)
	local n = px.size
	for _, rows in ipairs({true, false}) do
		local worst = 0
		for i = 0, n - 2 do
			worst = math.max(worst, line_diff(px, i, i + 1, rows))
		end
		local seam = line_diff(px, n - 1, 0, rows)
		-- (a tenth over: two lines of fine noise differ by chance)
		if seam > worst * 1.1 then
			return false, (rows and "rows" or "columns") .. ": " .. seam ..
					" across the edge, at most " .. worst .. " inside"
		end
	end
	return true
end
local n = 0
for _, size in ipairs(G.SIZES) do
	for octaves = 1, 4 do
		for g = 0, 4 do
			for seed = 1, 3 do
				local r = G.params{size = size, octaves = octaves, seed = seed * 7919,
					grain = g / 4, stretch = seed / 2 - 1, ridge = (g % 2) * 0.7,
					relief = 0.6, contrast = 0.3, levels = 0,
					color_a = "#c08040", color_b = "#204080"}
				local s_ok, s_why = seamless(G.render(r))
				if not s_ok then
					fail(size .. " px, " .. octaves .. " octaves, grain " .. r.grain ..
							", seed " .. r.seed .. ": not seamless, " .. s_why)
				end
				n = n + 1
			end
		end
	end
end
-- And every pattern at every size made, its element ids from 0
for _, size in ipairs(G.SIZES) do
	for _, pat in ipairs(G.PATTERNS) do
		for _, count in ipairs({1, 3, 7, 16}) do
			local px = G.render(G.params{pattern = pat, size = size, count = count,
				jitter = 1, gap = 1, bevel = 1, variation = 1, speckle = 1})
			if #px.rgba ~= size * size * 4 then
				fail(pat .. " " .. size .. " count " .. count .. ": " ..
						#px.rgba .. " bytes")
			end
		end
	end
end

-- The forms read back: packed, unpacked, packed again; a table's fields
-- as the compact form keeps them
for i, name in ipairs(G.PRESETS) do
	local r = G.preset(name, i)
	local s = G.pack(r)
	if #s ~= 7 + G.PACKED_LEN or s:find("[^0-9a-v]", 8) then
		fail(name .. ": " .. s .. " is not 53 characters of 0-9 a-v")
	end
	if G.pack(G.unpack(s)) ~= s then
		fail(name .. ": " .. s .. " reads back otherwise")
	end
	if G.pack(G.params(G.to_table(G.unpack(s)))) ~= s then
		fail(name .. ": its table form packs otherwise")
	end
	local m = G.mutate(r, i)
	if G.pack(G.params(G.pack(m))) ~= G.pack(m) then
		fail(name .. " mutated: reads back otherwise")
	end
end
-- A table with a value between the steps packs to the nearest one, and
-- makes the same pixels as its packed form
local t = {pattern = "bricks", grain = 0.123456, color_a = "#ABCDEF"}
local r = G.params(t)
if G.render(r).hash() ~= G.render(G.params(G.pack(r))).hash() or
		r.color_a ~= "#abcdef" then
	fail("a table's form and its packed form make other pixels")
end
-- Refused: a wrong length, a character out of the alphabet, a field out of
-- weave1's
for _, s in ipairs({"weave1:", "weave1:" .. ("0"):rep(52),
		"weave1:" .. ("w"):rep(53), "weave2:" .. ("0"):rep(53),
		"weave1:9" .. ("0"):rep(52)}) do
	if pcall(G.unpack, s) then
		fail(s .. " was read")
	end
end
for _, t2 in ipairs({{pattern = "plaid"}, {size = 20}, {grain = "x"},
		{color_a = "red"}, {seed = -1}, {nope = 1}}) do
	if pcall(G.params, t2) then
		fail("a table with a wrong field was read")
	end
end

print(n .. " textures checked for seams; " .. #G.PRESETS .. " presets")
if bad > 0 then
	print(bad .. " failed")
	os.exit(1)
end
print("PASS: weave_gen")
