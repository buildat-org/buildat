-- Buildat: extensions/weave/weave_gen.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- **weave1's generator** ([KIT_TEXTURE_DESIGNER]): a recipe in, the
-- pixels of a seamless pixel-art texture out (16, 32 or 64 px square,
-- RGBA, top row first). Plain Lua needing nothing: an app may copy this
-- file into itself and load it with buildat.run_script_file, as it may
-- blip_gen.lua, if it would rather not depend on weave.
--
--   local gen = <this file's return>
--   local px = gen.render(gen.params("weave1:..."))
--   -- px.size, px.rgba (size * size * 4 bytes), px:hash()
--
-- **No pen or brush**: a texture is its parameters (G.PARAMS, the
-- colours, the pattern and the size) and a seed. Noise mixes color_a
-- into color_b; a pattern (bricks, tiles, planks, cobbles, stripes) cuts
-- it into elements, each a little apart in shade, with gaps of gap_color
-- between and their edges lit from the top left; speckle dots it with
-- speckle_color; levels steps it into a few shades.
--
-- **Seamless**: every pattern and the noise repeat across the tile's
-- edges (the noise's lattice wraps), so it tiles in both directions.
--
-- **weave1 is frozen once released** (Kit's first stable release; until
-- then the format may change): a weave1 recipe makes the same pixels in
-- every later weave. A change to how a texture is made is a weave2 beside
-- this, never an edit of it; self_check() holds the hashes. So the
-- arithmetic is + - * / floor and sqrt only, which every platform rounds
-- the same (LuaJIT natively, Lua 5.1 on the web, the server's camera).
local G = {}

G.VERSION = 1
G.SIZES = {16, 32, 64}
G.PATTERNS = {"none", "bricks", "tiles", "planks", "cobbles", "stripes"}
-- Name, min, max, default, whole; in the compact form's order
G.PARAMS = {
	-- The noise: coarse (0) to fine (1); its finer layers (1...4); a soft
	-- mix (0) to two hard colours (1); how much of color_b; streaks across
	-- (+) or up (-); toward veins or cracks; embossed, lit from the top left
	{"grain", 0, 1, 0.3},
	{"octaves", 1, 4, 3, true},
	{"contrast", 0, 1, 0.2},
	{"balance", 0, 1, 0.5},
	{"stretch", -1, 1, 0},
	{"ridge", 0, 1, 0},
	{"relief", 0, 1, 0.3},
	-- The pattern: elements across (rows; a tile's or a cobble's grid);
	-- the gap's width; each row shifted by this much of an element; how
	-- irregular it is; each element's shade apart; its edges' bevel
	{"count", 1, 16, 4, true},
	{"gap", 0, 1, 0.3},
	{"offset", 0, 1, 0.5},
	{"jitter", 0, 1, 0.3},
	{"variation", 0, 1, 0.3},
	{"bevel", 0, 1, 0.4},
	-- Dots of speckle_color; the shades it is stepped into (0 smooth)
	{"speckle", 0, 1, 0},
	{"levels", 0, 16, 6, true},
}
G.COLORS = {
	{"color_a", "#808080"},
	{"color_b", "#606060"},
	{"gap_color", "#404040"},
	{"speckle_color", "#202020"},
}
local SEED_MAX = 1048575 -- 20 bits, four characters of the compact form
local BY_NAME = {}
for _, d in ipairs(G.PARAMS) do
	BY_NAME[d[1]] = d
end
local COLOR_DEFAULT = {}
for _, c in ipairs(G.COLORS) do
	COLOR_DEFAULT[c[1]] = c[2]
end
local function index_of(list)
	local t = {}
	for i, v in ipairs(list) do
		t[v] = i - 1
	end
	return t
end
local SIZE_INDEX = index_of(G.SIZES)
local PATTERN_INDEX = index_of(G.PATTERNS)

local floor, sqrt = math.floor, math.sqrt
local function clamp(x, lo, hi)
	return x < lo and lo or x > hi and hi or x
end

function G.defaults()
	local r = {v = G.VERSION, size = 16, pattern = "none", seed = 0}
	for _, d in ipairs(G.PARAMS) do
		r[d[1]] = d[4]
	end
	for _, c in ipairs(G.COLORS) do
		r[c[1]] = c[2]
	end
	return r
end

-- **The compact form**: "weave1:", then the size and the pattern as one
-- character each, the seed as four, each colour as five (24 bits), each
-- parameter in G.PARAMS' order as two (1024 steps; stretch in 1022, so
-- that 0 is exact) or a whole one as one. 53 characters of 0-9 a-v
-- (base 32, one case: the engine's resource names are told apart without
-- their case, and weave.name() is this string)
local B32 = "0123456789abcdefghijklmnopqrstuv"
local B32_INDEX = {}
for i = 1, 32 do
	B32_INDEX[B32:sub(i, i)] = i - 1
end
G.PACKED_LEN = 1 + 1 + 4 + 5 * #G.COLORS
for _, d in ipairs(G.PARAMS) do
	G.PACKED_LEN = G.PACKED_LEN + (d[5] and 1 or 2)
end
local function put(out, v, chars)
	local digits = {}
	for i = chars, 1, -1 do
		local q = v % 32
		digits[i] = B32:sub(q + 1, q + 1)
		v = floor(v / 32)
	end
	out[#out + 1] = table.concat(digits)
end
local function quantise(d, x)
	if d[5] then
		return floor(x + 0.5) - d[2]
	elseif d[2] < 0 then
		return floor(x * 511 + 0.5) + 511
	end
	return floor(x * 1023 + 0.5)
end
local function unquantise(d, q)
	if d[5] then
		return q + d[2]
	elseif d[2] < 0 then
		return (q - 511) / 511
	end
	return q / 1023
end
-- "#rrggbb" as a number, nil for anything else
local function hex(s)
	if type(s) ~= "string" or not s:match("^#%x%x%x%x%x%x$") then
		return nil
	end
	return tonumber(s:sub(2), 16)
end
local function hex_string(n)
	return string.format("#%06x", n)
end

function G.pack(r)
	local out = {"weave1:"}
	put(out, SIZE_INDEX[r.size], 1)
	put(out, PATTERN_INDEX[r.pattern], 1)
	put(out, r.seed, 4)
	for _, c in ipairs(G.COLORS) do
		put(out, hex(r[c[1]]), 5)
	end
	for _, d in ipairs(G.PARAMS) do
		put(out, quantise(d, r[d[1]]), d[5] and 1 or 2)
	end
	return table.concat(out)
end

function G.unpack(s)
	if type(s) ~= "string" or s:sub(1, 7) ~= "weave1:" then
		error("weave: not a weave1 recipe: " .. tostring(s):sub(1, 60), 3)
	end
	local body = s:sub(8)
	if #body ~= G.PACKED_LEN or body:find("[^0-9a-v]") then
		error("weave: a weave1 recipe is \"weave1:\" and " .. G.PACKED_LEN ..
				" characters of 0-9 a-v", 3)
	end
	local pos = 1
	local function get(chars)
		local v = 0
		for _ = 1, chars do
			v = v * 32 + B32_INDEX[body:sub(pos, pos)]
			pos = pos + 1
		end
		return v
	end
	local r = {v = G.VERSION}
	r.size = G.SIZES[get(1) + 1]
	r.pattern = G.PATTERNS[get(1) + 1]
	if not r.size or not r.pattern then
		error("weave: a weave1 recipe's size or pattern is not one of weave1's",
				3)
	end
	r.seed = get(4)
	for _, c in ipairs(G.COLORS) do
		local n = get(5)
		if n > 16777215 then
			error("weave: a weave1 recipe's " .. c[1] .. " is past #ffffff", 3)
		end
		r[c[1]] = hex_string(n)
	end
	for _, d in ipairs(G.PARAMS) do
		local q = get(d[5] and 1 or 2)
		local x = unquantise(d, q)
		if x < d[2] or x > d[3] then
			error("weave: a weave1 recipe's " .. d[1] .. " is out of its range",
					3)
		end
		r[d[1]] = x
	end
	return r
end

-- Fields of a table checked onto r: known names, numbers in range (a
-- whole one rounded), "#rrggbb" colours
local function apply(r, t)
	for k, v in pairs(t) do
		if k == "v" then
			if v ~= G.VERSION then
				error("weave: v = " .. tostring(v) .. ", this is weave1", 3)
			end
		elseif k == "size" then
			if SIZE_INDEX[v] == nil then
				error("weave: size is " .. tostring(v) .. ", not 16, 32 or 64", 3)
			end
			r.size = v
		elseif k == "pattern" then
			if PATTERN_INDEX[v] == nil then
				error("weave: pattern is " .. tostring(v) .. ", not one of " ..
						table.concat(G.PATTERNS, ", "), 3)
			end
			r.pattern = v
		elseif k == "seed" then
			if type(v) ~= "number" or v ~= floor(v) or v < 0 or
					v > SEED_MAX then
				error("weave: seed is " .. tostring(v) .. ", not a whole 0.." ..
						SEED_MAX, 3)
			end
			r.seed = v
		elseif COLOR_DEFAULT[k] then
			if not hex(v) then
				error("weave: " .. k .. " is " .. tostring(v) ..
						", not \"#rrggbb\"", 3)
			end
			r[k] = v:lower()
		elseif k ~= 1 then
			local d = BY_NAME[k]
			if not d then
				error("weave: no parameter " .. tostring(k), 3)
			end
			if type(v) ~= "number" or v ~= v then
				error("weave: " .. k .. " is not a number", 3)
			end
			v = clamp(v, d[2], d[3])
			r[k] = d[5] and floor(v + 0.5) or v
		end
	end
	return r
end

-- A recipe in any of weave1's forms, as a full table of its fields, each
-- as the compact form has it (so a table and its packed string make the
-- same pixels):
--   "weave1:..."                        the compact form
--   {v = 1, pattern = "bricks", ...}    the table, every field optional
--   {"weave1:...", grain = 0.5}         both: the table's fields override
function G.params(recipe)
	local r
	if type(recipe) == "string" then
		r = G.unpack(recipe)
	elseif type(recipe) == "table" then
		r = recipe[1] ~= nil and G.unpack(recipe[1]) or G.defaults()
		apply(r, recipe)
		r = G.unpack(G.pack(r))
	else
		error("weave: a recipe is a weave1 string or a table, not a " ..
				type(recipe), 2)
	end
	return r
end

-- The table form: every field by name, for editing outside weave
function G.to_table(r)
	local t = {v = G.VERSION, size = r.size, pattern = r.pattern,
		seed = r.seed}
	for _, c in ipairs(G.COLORS) do
		t[c[1]] = r[c[1]]
	end
	for _, d in ipairs(G.PARAMS) do
		t[d[1]] = r[d[1]]
	end
	return t
end

-- As Lua source, a field a line in the compact form's order
function G.table_source(t, indent)
	indent = indent or "\t"
	local out = {"{", indent .. "v = " .. G.VERSION .. ", size = " .. t.size ..
			", pattern = \"" .. t.pattern .. "\", seed = " .. t.seed .. ","}
	for _, c in ipairs(G.COLORS) do
		out[#out + 1] = indent .. c[1] .. " = \"" .. t[c[1]] .. "\","
	end
	for _, d in ipairs(G.PARAMS) do
		out[#out + 1] = indent .. d[1] .. " = " ..
				string.format("%.4g", t[d[1]]) .. ","
	end
	out[#out + 1] = "}"
	return table.concat(out, "\n")
end

-- **A random number generator of its own** (Park and Miller's), so a
-- recipe is the same pixels everywhere: math.random is not the same
-- between LuaJIT and Lua 5.1. Exact in doubles.
function G.rng(seed)
	local s = floor(seed or 1) % 2147483646 + 1
	local r = {}
	function r.frnd(range)
		s = (s * 16807) % 2147483647
		return (s - 1) / 2147483646 * range
	end
	-- 0..n, each as likely
	function r.rnd(n)
		return math.min(n, floor(r.frnd(n + 1)))
	end
	return r
end

-- **A permutation of 0..255 by the seed** (Perlin's table), from which
-- every random value of a texture is read: P[(P[i] + j) % 256] is a
-- value for the pair (i, j)
local function permutation(seed)
	local r = G.rng(seed * 7 + 3)
	local p = {}
	for i = 0, 255 do
		p[i] = i
	end
	for i = 255, 1, -1 do
		local j = r.rnd(i)
		p[i], p[j] = p[j], p[i]
	end
	return p
end

-- Each row's or column's first pixel and the one past its last, for n
-- of them across `size` pixels (whole pixels, the last ending at size)
local function splits(n, size)
	local at = {}
	for i = 0, n do
		at[i] = floor(i * size / n + 0.5)
	end
	return at
end
local function which(at, n, v)
	local i = floor(v * n / at[n])
	while i > 0 and at[i] > v do
		i = i - 1
	end
	while i < n - 1 and at[i + 1] <= v do
		i = i + 1
	end
	return i
end

-- **The noise**: periodic value noise, octaves of a lattice that wraps
-- at the tile's edges, each finer one half as strong; 0...1 a pixel, by
-- y * size + x (from 0)
local function noise_field(r, size, P)
	local base = 1 + floor(r.grain * 15 + 0.5)
	local cx, cy = base, base
	if r.stretch > 0 then
		cx = math.max(1, floor(base / (1 + 3 * r.stretch) + 0.5))
	elseif r.stretch < 0 then
		cy = math.max(1, floor(base / (1 - 3 * r.stretch) + 0.5))
	end
	local h = {}
	for i = 0, size * size - 1 do
		h[i] = 0
	end
	local total, amp = 0, 1
	for o = 1, r.octaves do
		local nx, ny = math.min(size, cx), math.min(size, cy)
		-- The lattice's values, a value a point
		local L = {}
		for j = 0, ny - 1 do
			for i = 0, nx - 1 do
				L[j * nx + i] = P[(P[(i + o * 67) % 256] + j + o * 29) % 256] /
						255
			end
		end
		for y = 0, size - 1 do
			local v = (y + 0.5) * ny / size
			local j0 = floor(v)
			local fv = v - j0
			fv = fv * fv * (3 - 2 * fv)
			local r0, r1 = (j0 % ny) * nx, ((j0 + 1) % ny) * nx
			for x = 0, size - 1 do
				local u = (x + 0.5) * nx / size
				local i0 = floor(u)
				local fu = u - i0
				fu = fu * fu * (3 - 2 * fu)
				local a, b = i0 % nx, (i0 + 1) % nx
				local top = L[r0 + a] + (L[r0 + b] - L[r0 + a]) * fu
				local bot = L[r1 + a] + (L[r1 + b] - L[r1 + a]) * fu
				local k = y * size + x
				h[k] = h[k] + (top + (bot - top) * fv) * amp
			end
		end
		total = total + amp
		amp = amp * 0.5
		cx, cy = cx * 2, cy * 2
	end
	for i = 0, size * size - 1 do
		local n = h[i] / total
		-- Ridged toward veins: 1 where the noise crosses its middle
		local ridged = 1 - math.abs(2 * n - 1)
		h[i] = n + (ridged - n) * r.ridge
	end
	return h
end

-- **The pattern's element at a pixel**: its id (a number, -1 a gap), and
-- its edge's light (1 its top or left, -1 its bottom or right, between
-- for a cobble's round), for a whole tile's pixels as two tables
local function pattern_field(r, size, P)
	local id, edge = {}, {}
	local n = r.count
	local gap = floor(r.gap * 3 * size / 16 + 0.5)
	local bw = math.max(1, floor(size / 16))
	local pat = r.pattern
	if pat == "none" then
		for i = 0, size * size - 1 do
			id[i], edge[i] = 0, 0
		end
		return id, edge
	end
	if pat == "cobbles" then
		-- A cell's point, jittered in its cell; the nearest point's cell is
		-- the stone, and where the second nearest is about as near, the gap
		local cs = size / n
		local pts = {}
		for j = 0, n - 1 do
			for i = 0, n - 1 do
				local k = j * n + i
				local jx = P[(P[(i + 11) % 256] + j + 5) % 256] / 255 - 0.5
				local jy = P[(P[(i + 97) % 256] + j + 41) % 256] / 255 - 0.5
				pts[k] = {(i + 0.5 + jx * r.jitter) * cs,
					(j + 0.5 + jy * r.jitter) * cs}
			end
		end
		for y = 0, size - 1 do
			local cj = floor(y / cs)
			for x = 0, size - 1 do
				local ci = floor(x / cs)
				local d1, d2, best, bdx, bdy = 1e9, 1e9, 0, 0, 0
				for dj = -2, 2 do
					for di = -2, 2 do
						local i, j = ci + di, cj + dj
						local wi, wj = i % n, j % n
						local p = pts[wj * n + wi]
						-- Its copy beside the tile, for the wrap
						local px = p[1] + (i - wi) * cs
						local py = p[2] + (j - wj) * cs
						local dx, dy = x + 0.5 - px, y + 0.5 - py
						local d = dx * dx + dy * dy
						if d < d1 then
							d2 = d1
							d1, best, bdx, bdy = d, wj * n + wi, dx, dy
						elseif d < d2 then
							d2 = d
						end
					end
				end
				local k = y * size + x
				if sqrt(d2) - sqrt(d1) < gap then
					id[k], edge[k] = -1, 0
				else
					id[k] = best
					edge[k] = clamp(-(bdx + bdy) / (cs * 0.7), -1, 1)
				end
			end
		end
		return id, edge
	end
	-- Rows: bricks (two rows' height wide), tiles (square), planks (a row
	-- a board, a joint where its row's shift puts it) and stripes (rows
	-- only)
	local cols = pat == "bricks" and math.max(1, floor(n / 2 + 0.5)) or
			pat == "tiles" and n or 1
	local rows = splits(n, size)
	local colat = splits(cols, size)
	local cw = size / cols
	for y = 0, size - 1 do
		local ri = which(rows, n, y)
		local jit = P[(P[(ri + 23) % 256] + 71) % 256] / 255 - 0.5
		local shift = floor((ri * r.offset + jit * r.jitter) * cw + 0.5) % size
		local y0, y1 = rows[ri], rows[ri + 1] - 1
		for x = 0, size - 1 do
			local xs = (x - shift) % size
			local ci = which(colat, cols, xs)
			local x0, x1 = colat[ci], colat[ci + 1] - 1
			local k = y * size + x
			local vgap = pat ~= "stripes" and xs - x0 < gap
			if y - y0 < gap or vgap then
				id[k], edge[k] = -1, 0
			else
				id[k] = ri * 64 + ci
				local top = y - y0 - gap < bw or (pat ~= "stripes" and
						xs - x0 - gap < bw)
				local bottom = y1 - y < bw or (pat ~= "stripes" and x1 - xs < bw)
				edge[k] = top and 1 or bottom and -1 or 0
			end
		end
	end
	return id, edge
end

local function rgb(s)
	local n = hex(s)
	return floor(n / 65536) / 255, floor(n / 256) % 256 / 255, n % 256 / 255
end

-- **The pixels**: {size, rgba (a string of size * size * 4 bytes, top
-- row first), hash()}
function G.render(r)
	local size = r.size
	local P = permutation(r.seed)
	local h = noise_field(r, size, P)
	local id, edge = pattern_field(r, size, P)
	local ar, ag, ab = rgb(r.color_a)
	local br, bg, bb = rgb(r.color_b)
	local gr, gg, gb = rgb(r.gap_color)
	local sr, sg, sb = rgb(r.speckle_color)
	-- The mix's steepness and threshold
	local k = 1 + r.contrast * r.contrast * 24
	local th = 1 - r.balance
	local levels = r.levels
	local var = r.variation
	local relief = r.relief * 3
	local bevel = r.bevel * 0.35
	local spk = r.speckle * 0.3
	local elements = r.pattern ~= "none"
	local char = string.char
	local out = {}
	for y = 0, size - 1 do
		local yu, yd = ((y - 1) % size) * size, ((y + 1) % size) * size
		for x = 0, size - 1 do
			local i = y * size + x
			local e = id[i]
			-- The element's own randomness: its shade and its mix apart
			local ev1, ev2 = 0, 0
			if e >= 0 and elements then
				ev1 = P[(P[e % 256] + floor(e / 256) * 13 + 101) % 256] / 255 - 0.5
				ev2 = P[(P[(e + 59) % 256] + floor(e / 256) * 7 + 3) % 256] / 255 -
						0.5
			end
			local t = clamp(0.5 + (h[i] - th) * k + ev2 * var * 0.5, 0, 1)
			-- Emboss: the noise up and left of it against down and right
			local rel = (h[yu + (x - 1) % size] - h[yd + (x + 1) % size]) *
					relief
			local s = 1 + clamp(rel, -0.45, 0.45) + ev1 * var * 0.5 +
					edge[i] * bevel
			if levels >= 2 then
				t = floor(t * (levels - 1) + 0.5) / (levels - 1)
				s = floor(s * levels + 0.5) / levels
			end
			local cr, cg, cb
			if e < 0 then
				cr, cg, cb = gr, gg, gb
			elseif spk > 0 and
					P[(P[(x + 7) % 256] + y + 53) % 256] / 255 < spk then
				cr, cg, cb = sr, sg, sb
			else
				cr, cg, cb = ar + (br - ar) * t, ag + (bg - ag) * t,
						ab + (bb - ab) * t
			end
			out[i + 1] = char(floor(clamp(cr * s, 0, 1) * 255 + 0.5),
					floor(clamp(cg * s, 0, 1) * 255 + 0.5),
					floor(clamp(cb * s, 0, 1) * 255 + 0.5), 255)
		end
	end
	local px = {size = size, rgba = table.concat(out)}
	function px.hash()
		return G.hash(px.rgba)
	end
	return px
end

-- Two sums of the bytes, 16 hex digits: the self-check's
function G.hash(s)
	local a, b = 0, 7
	for i = 1, #s do
		local c = s:byte(i)
		a = (a * 31 + c) % 4294967296
		b = (b * 1048573 + c) % 4294967291
	end
	return string.format("%08x%08x", a, b)
end

-- **The presets**: a recipe of each kind, and the same kind again at
-- another seed: its noise, and its colours and numbers nudged a little
G.PRESETS = {"grass", "dirt", "stone", "cobble", "bricks", "planks", "sand",
	"regolith", "metal", "ice"}
local PRESET = {
	grass = {pattern = "none", color_a = "#4f8a2c", color_b = "#6aa83a",
		speckle_color = "#8cc84a", grain = 0.75, octaves = 2, contrast = 0.35,
		balance = 0.45, relief = 0.35, speckle = 0.25, levels = 5},
	dirt = {pattern = "none", color_a = "#7a5434", color_b = "#5e3f26",
		speckle_color = "#9a7a58", grain = 0.55, octaves = 3, contrast = 0.3,
		balance = 0.5, relief = 0.4, speckle = 0.2, levels = 5},
	stone = {pattern = "none", color_a = "#8c8c8c", color_b = "#6e6e72",
		speckle_color = "#5a5a5e", grain = 0.35, octaves = 4, contrast = 0.4,
		balance = 0.45, ridge = 0.3, relief = 0.45, speckle = 0.1, levels = 5},
	cobble = {pattern = "cobbles", color_a = "#8a8a8a", color_b = "#6c6c70",
		gap_color = "#3e3e40", grain = 0.5, octaves = 3, contrast = 0.2,
		relief = 0.3, count = 3, gap = 0.35, jitter = 0.6, variation = 0.5,
		bevel = 0.7, levels = 5},
	bricks = {pattern = "bricks", color_a = "#9c4a32", color_b = "#7e3a28",
		gap_color = "#c4bcae", grain = 0.6, octaves = 2, contrast = 0.2,
		relief = 0.25, count = 4, gap = 0.34, offset = 0.5, jitter = 0.1,
		variation = 0.4, bevel = 0.45, levels = 5},
	planks = {pattern = "planks", color_a = "#a87a48", color_b = "#8a603a",
		gap_color = "#4a3420", grain = 0.45, octaves = 3, contrast = 0.3,
		stretch = 0.9, relief = 0.2, count = 4, gap = 0.34, offset = 0.35,
		jitter = 0.5, variation = 0.35, bevel = 0.35, levels = 5},
	sand = {pattern = "none", color_a = "#dcc890", color_b = "#c8b07a",
		speckle_color = "#b09868", grain = 0.7, octaves = 2, contrast = 0.15,
		stretch = 0.5, relief = 0.3, speckle = 0.15, levels = 4},
	regolith = {pattern = "none", color_a = "#9a948c", color_b = "#7c7670",
		speckle_color = "#5c5854", grain = 0.4, octaves = 4, contrast = 0.35,
		balance = 0.45, relief = 0.7, speckle = 0.3, levels = 5},
	metal = {pattern = "tiles", color_a = "#a4aab0", color_b = "#8c9298",
		gap_color = "#50565c", grain = 0.2, octaves = 2, contrast = 0.1,
		stretch = 0.6, relief = 0.1, count = 2, gap = 0.34, offset = 0,
		jitter = 0, variation = 0.15, bevel = 0.8, levels = 6},
	ice = {pattern = "none", color_a = "#94c4e4", color_b = "#e8f6fc",
		grain = 0.2, octaves = 3, contrast = 0.55, balance = 0.12, ridge = 1,
		relief = 0.15, levels = 5},
}

-- A colour nudged: each channel by up to `by` either way
local function nudge(s, frnd, by)
	local n = hex(s)
	local c = {floor(n / 65536), floor(n / 256) % 256, n % 256}
	local d = frnd(2 * by) - by
	for i = 1, 3 do
		c[i] = clamp(floor(c[i] + d + frnd(by) - by / 2 + 0.5), 0, 255)
	end
	return hex_string(c[1] * 65536 + c[2] * 256 + c[3])
end

-- Every number into its range, a whole one whole, as G.params does
local function settle(r)
	return G.unpack(G.pack(r))
end

function G.preset(name, seed)
	local base = PRESET[name]
	if not base then
		error("weave: no preset " .. tostring(name), 2)
	end
	local rnd = G.rng(seed)
	local r = apply(G.defaults(), base)
	r.seed = floor(rnd.frnd(SEED_MAX + 1))
	for _, c in ipairs(G.COLORS) do
		r[c[1]] = nudge(r[c[1]], rnd.frnd, 10)
	end
	-- (one that is off stays off: a little speckle is another texture)
	for _, d in ipairs(G.PARAMS) do
		if not d[5] and d[1] ~= "stretch" and r[d[1]] ~= 0 then
			r[d[1]] = clamp(r[d[1]] + rnd.frnd(0.08) - 0.04, d[2], d[3])
		end
	end
	return settle(r)
end

-- Anything: a pattern, two colours near each other and a gap's darker,
-- the numbers anywhere in their ranges
function G.random(seed)
	local rnd = G.rng(seed)
	local frnd = rnd.frnd
	local r = G.defaults()
	r.pattern = G.PATTERNS[rnd.rnd(#G.PATTERNS - 1) + 1]
	r.size = 16
	r.seed = floor(frnd(SEED_MAX + 1))
	local c = {floor(frnd(256)), floor(frnd(256)), floor(frnd(256))}
	local function col(scale, by)
		local o = {}
		for i = 1, 3 do
			o[i] = clamp(floor(c[i] * scale + frnd(2 * by) - by + 0.5), 0, 255)
		end
		return hex_string(o[1] * 65536 + o[2] * 256 + o[3])
	end
	r.color_a = col(1, 8)
	r.color_b = col(0.8, 24)
	r.gap_color = col(0.45, 16)
	r.speckle_color = col(1.25, 32)
	for _, d in ipairs(G.PARAMS) do
		r[d[1]] = d[5] and d[2] + rnd.rnd(d[3] - d[2]) or
				d[2] + frnd(d[3] - d[2])
	end
	-- Fewer and smaller extremes where they read as noise
	r.count = 1 + rnd.rnd(7)
	r.speckle = frnd(0.4)
	r.gap = frnd(0.6)
	r.levels = 3 + rnd.rnd(5)
	-- Away from one colour all over: a balance near either end, a
	-- contrast near none or the noise flattened by relief at none
	r.balance = 0.3 + frnd(0.4)
	r.contrast = 0.1 + frnd(0.5)
	r.relief = 0.2 + frnd(0.5)
	r.grain = 0.2 + frnd(0.7)
	return settle(r)
end

-- Each number moved by up to `amount` (0.05 when not given) half the
-- time, the colours by a few steps; the pattern, size and seed kept
function G.mutate(r, seed, amount)
	local step = 2 * (amount or 0.05)
	local rnd = G.rng(seed)
	local q = {}
	for k, v in pairs(r) do
		q[k] = v
	end
	for _, d in ipairs(G.PARAMS) do
		if rnd.rnd(1) == 1 then
			if d[5] then
				q[d[1]] = clamp(q[d[1]] + rnd.rnd(2) - 1, d[2], d[3])
			else
				q[d[1]] = clamp(q[d[1]] + (rnd.frnd(step) - step / 2) *
						(d[3] - d[2]), d[2], d[3])
			end
		end
	end
	for _, c in ipairs(G.COLORS) do
		if rnd.rnd(1) == 1 then
			q[c[1]] = nudge(q[c[1]], rnd.frnd, 12)
		end
	end
	return settle(q)
end

-- **The self-check**: each preset at seed 1, its pixels against the
-- hashes weave1 was made with, and its compact form read back the same.
-- A change that moves one is a weave2. -> true, or false and the presets
-- that differ
G.HASHES = {
	grass = "9e4e0e0254ec447b",
	dirt = "08269956767ef9ea",
	stone = "2c9b354a477a6800",
	cobble = "d9e0b82d87eed159",
	bricks = "6558d5cefc94f216",
	planks = "7f436e6c543c5822",
	sand = "f1c2da5f7f07d8d3",
	regolith = "ae0854ce8dd09ae9",
	metal = "cb332aad7c9ab924",
	ice = "549495413ea2babd",
}
function G.self_check()
	local bad = {}
	for _, name in ipairs(G.PRESETS) do
		local r = G.preset(name, 1)
		local h = G.render(r).hash()
		if h ~= G.HASHES[name] then
			bad[#bad + 1] = name .. " hashes " .. h .. ", not " ..
					tostring(G.HASHES[name])
		end
		if G.pack(G.unpack(G.pack(r))) ~= G.pack(r) then
			bad[#bad + 1] = name .. "'s compact form reads back otherwise"
		end
	end
	return #bad == 0, bad
end

return G
-- vim: set noet ts=4 sw=4:
