-- [LAUNCH_WORLD]: the recursive ornament generator, and the maps it feeds
-- the material library.
--
-- **One height field and one inlay mask per texture; everything else is
-- derived.** The height carries the relief -- the meander's band, the
-- socket field's holes -- and the inlay says where a second material is
-- set into the first. From those two come the albedo, the normal and
-- (later) the roughness, and the same height thresholded is what carves
-- the voxels once the room is a voxelworld, so a pattern is authored once
-- and appears both as relief on a face and as shape in the grid.
--
-- Nothing here is loaded from a file: the room's whole point is how much
-- a program can leave out, and a texture is a few hundred lines of Lua
-- against a few megabytes of PNG.
-- Its own, rather than world.lua's: a file run on its own has no
-- globals of the room's ([LAUNCH_SANDBOX]'s run_extension_file).
-- **require answers the safe interface inside the sandbox and the whole
-- extension outside it**, which is the one difference the two contexts
-- have that a file like this can see. Asked by something the safe half
-- has, because it raises on a name it does not know rather than
-- answering nil -- so `urho3d.safe` is not a question that can be put
-- to it.
local urho3d = require("buildat/core/urho3d")
local magic = urho3d.Vector3 and urho3d or urho3d.safe

local M = {}

-- A generator with its own state, because the sandbox shares math.random
-- and a pattern has to be the same every session: a server's address
-- seeds its own sigil, and a slab keeps its face between runs.
-- simplified: a 32-bit xorshift, which is plenty for deciding which
-- quadrant to raise; the upgrade is nothing, since nobody is betting on
-- it.
local function rng(seed)
	local s = seed % 2147483647
	if s <= 0 then s = s + 2147483646 end
	return function(n)
		s = (s * 16807) % 2147483647
		return n and (s % n) + 1 or s / 2147483647
	end
end

-- A string's seed, so "example.org:30000" always draws the same sigil
function M.seed_of(text)
	local h = 5381
	for i = 1, #text do
		h = (h * 33 + text:byte(i)) % 2147483647
	end
	return h
end

-- A field is a flat array of w*h numbers in 0..1, indexed from 1
-- (declared before the patterns, which all build one).
--
-- **Width and height, not one size** ([SIGIL_ROUND], 2026-09-24: a run
-- of eight tiles is a strip eight times wider than it is tall, and
-- every one of these carried a single `size` for both axes). `size`
-- stays as the width, because everything that asks a square field for
-- its size means that; `rows` is the height.
local function field(size, v, rows)
	local h = rows or size
	local f = {size = size, rows = h}
	for i = 1, size * h do
		f[i] = v or 0
	end
	return f
end
M.field = field

local function at(f, x, y)
	if x < 0 or y < 0 or x >= f.size or y >= (f.rows or f.size) then
		return 0
	end
	return f[y * f.size + x + 1]
end
M.at = at

local function put(f, x, y, v)
	if x < 0 or y < 0 or x >= f.size or y >= (f.rows or f.size) then
		return
	end
	f[y * f.size + x + 1] = v
end
-- Exported beside at() and box(): a caller building a strip out of
-- tiles writes into a field of its own ([SIGIL_ROUND])
M.put = put

local function box(f, x0, y0, w, h, v)
	for y = y0, y0 + h - 1 do
		for x = x0, x0 + w - 1 do
			put(f, x, y, v)
		end
	end
end
M.box = box

-- **The meander**, which is the Greek key of the reference frame. One
-- unit is a square spiral drawn as a walked path; the band repeats it
-- along the texture and mirrors every other one, which is what makes it
-- read as a chain rather than as a row of stamps.
--
-- Recursive because the plan asks for it and because it is what the
-- classical version does: at depth > 1 the unit's own centre carries a
-- smaller meander, so a slab looked at closely has ornament inside its
-- ornament.
local function meander_unit(h, x0, y0, n, t, depth)
	-- t is the stroke, n the unit's side. The spiral: three sides of a
	-- square, then in by 2t and around again, until there is no room.
	local x, y, s = x0, y0, n
	local turns = 0
	while s > t * 3 and turns < 6 do
		box(h, x, y, s, t, 1)                    -- top
		box(h, x + s - t, y, t, s, 1)            -- right
		box(h, x, y + s - t, s - t * 2, t, 1)    -- bottom, short
		x = x + t * 2
		y = y + t * 2
		s = s - t * 4
		turns = turns + 1
	end
	if depth > 1 and n > t * 10 then
		meander_unit(h, x0 + n / 4, y0 + n / 4, n / 2, math.max(1, t / 2),
				depth - 1)
	end
end

-- size: the texture's side. band: how tall the ornamented strip is, as a
-- share of it -- the rest is plain face, which is what a slab mostly is.
function M.meander(size, opts)
	opts = opts or {}
	local h = field(size)
	local inlay = field(size)
	local units = opts.units or 4
	local n = math.floor(size / units)
	local t = math.max(1, math.floor(n / 7))
	local band_y = math.floor(size * (opts.band_y or 0.30))
	for u = 0, units - 1 do
		meander_unit(h, u * n, band_y, n, t, opts.depth or 2)
	end
	-- The band's own edges: two rules above and below it, which is what
	-- separates ornament from face in every classical frieze
	box(h, 0, band_y - t * 2, size, t, 1)
	box(h, 0, band_y + n + t, size, t, 1)
	-- The inlay is the band itself: a second material set into the stone,
	-- which is where the room's purple goes ([LAUNCH_WORLD]'s colour
	-- roles: structure and ornament, never state)
	box(inlay, 0, band_y - t * 2, size, n + t * 4, 1)
	return h, inlay
end

-- **The socket field**: the perforated blocks of the reference frame,
-- and the one pattern that is a grid rather than a path. Recursive by
-- subdivision -- a cell either takes a socket or splits into four, so
-- the field has more than one scale in it without a second algorithm.
local function socket_cell(h, inlay, x0, y0, n, r, depth)
	if depth > 0 and n > 12 and r() < 0.45 then
		local m = math.floor(n / 2)
		for _, q in ipairs({{0, 0}, {m, 0}, {0, m}, {m, m}}) do
			socket_cell(h, inlay, x0 + q[1], y0 + q[2], m, r, depth - 1)
		end
		return
	end
	local pad = math.max(1, math.floor(n / 5))
	local s = n - pad * 2
	if s < 2 then
		return
	end
	-- The socket is a recess, so it is low where the face is high
	box(h, x0 + pad, y0 + pad, s, s, 0)
	box(inlay, x0 + pad, y0 + pad, s, s, 1)
	-- ...with a lip around it, which is what catches a raking light
	local lip = math.max(1, math.floor(pad / 2))
	box(h, x0 + pad - lip, y0 + pad - lip, s + lip * 2, lip, 1)
	box(h, x0 + pad - lip, y0 + pad + s, s + lip * 2, lip, 1)
	box(h, x0 + pad - lip, y0 + pad, lip, s, 1)
	box(h, x0 + pad + s, y0 + pad, lip, s, 1)
end

function M.sockets(size, opts)
	opts = opts or {}
	local h = field(size, 0.55)
	local inlay = field(size)
	local r = rng(opts.seed or 12345)
	local cells = opts.cells or 4
	local n = math.floor(size / cells)
	for cy = 0, cells - 1 do
		for cx = 0, cells - 1 do
			socket_cell(h, inlay, cx * n, cy * n, n, r, opts.depth or 2)
		end
	end
	return h, inlay
end

-- **A sigil**, which is what a server gets instead of a logo: its
-- address seeds a recursive subdivision, so the pattern is its own, the
-- same every session, and no asset anywhere. Mirrored twice, because a
-- mark reads as a mark when it is symmetric and as noise when it is not.
function M.sigil(size, seed, depth)
	local h = field(size)
	local inlay = field(size)
	local r = rng(seed)
	local half = math.floor(size / 2)
	local function carve(x0, y0, n, d)
		if n < 3 then
			return
		end
		if d <= 0 or r() < 0.30 then
			box(h, x0, y0, n, n, 1)
			if r() < 0.5 then
				box(inlay, x0, y0, n, n, 1)
			end
			return
		end
		local m = math.floor(n / 2)
		for _, q in ipairs({{0, 0}, {m, 0}, {0, m}, {m, m}}) do
			if r() < 0.62 then
				carve(x0 + q[1], y0 + q[2], m, d - 1)
			end
		end
	end
	carve(0, 0, half, depth or 4)
	-- The two mirrors
	for y = 0, half - 1 do
		for x = 0, half - 1 do
			local v, iv = at(h, x, y), at(inlay, x, y)
			put(h, size - 1 - x, y, v);        put(inlay, size - 1 - x, y, iv)
			put(h, x, size - 1 - y, v);        put(inlay, x, size - 1 - y, iv)
			put(h, size - 1 - x, size - 1 - y, v)
			put(inlay, size - 1 - x, size - 1 - y, iv)
		end
	end
	return h, inlay
end

-- **A mark for an orb**: the same recursion as a sigil, but kept to the
-- middle of the texture and mirrored left-to-right only, so that on
-- Sphere.mdl's spherical UVs it reads as one mark on one face rather
-- than a pattern wrapped round the ball. White is the orb's own light;
-- the mark is the hole cut in it.
--
-- simplified: generated from the name rather than taken from the
-- launchable's own icon (`M.launch = {title, icon, run}`), because this
-- room has no launchables in it yet. The upgrade is drawing the icon
-- into the same middle region, which changes nothing else.
-- **A mark for an orb**: a grid of cells, on or off from the name's
-- seed, mirrored left to right so it reads as a mark and not as noise.
-- White is the orb's own light; the mark is the hole cut in it.
--
-- **Seven cells at a fill of .62** ([SIGIL_ROUND], user 2026-09-24):
-- "it looks like an ancient stone glyph", where the lighter fills read
-- as a weird letter and nine cells reads as circuitry. Seven is odd, so
-- there is a centre column to hang a figure on; an even count gives
-- every seed a pair of halves.
--
-- **This replaced a recursive subdivision**, which the round found to
-- be the wrong generator rather than a badly tuned one: its vocabulary
-- is axis-aligned squares, so it drew specks (0.7 to 7.6% ink against
-- a 16% target), or -- held to the target -- a filled square, or, that
-- square outlined, a bounding box. A grid has the two properties the
-- round judged on by construction. **The ink is a count and not a
-- hope**, so no seed draws nothing and none has to be searched for;
-- and two seeds plainly look unlike each other.
--
-- The fill is the knob if a sigil ever reads too heavy or too light
-- beside a game's own logo: .38 to .62 moves the ink from about 8% to
-- about 12% and barely moves the silhouette.
local MARK_CELLS, MARK_FILL = 7, 0.62

function M.mark(size, seed)
	local f = field(size, 1)
	local r = rng(seed)
	local half = math.ceil(MARK_CELLS / 2)
	-- Draw the left half and mirror it: the cells that can be on are
	-- half * MARK_CELLS, and a shuffle picks which, so the count is
	-- exact rather than the sum of that many coin flips.
	local idx = {}
	for k = 0, half * MARK_CELLS - 1 do idx[#idx + 1] = k end
	for k = #idx, 2, -1 do
		local j2 = math.floor(r() * k) + 1
		idx[k], idx[j2] = idx[j2], idx[k]
	end
	local on = {}
	for k = 1, math.floor(half * MARK_CELLS * MARK_FILL + 0.5) do
		on[idx[k]] = true
	end
	local m0, m1 = math.floor(size * 0.28), math.floor(size * 0.72)
	local cw = (m1 - m0) / MARK_CELLS
	for cy = 0, MARK_CELLS - 1 do
		for cx = 0, MARK_CELLS - 1 do
			local sx = (cx < half) and cx or (MARK_CELLS - 1 - cx)
			if on[sx * MARK_CELLS + cy] then
				local x0 = math.floor(m0 + cx * cw)
				local y0 = math.floor(m0 + cy * cw)
				box(f, x0, y0, math.floor(m0 + (cx + 1) * cw) - x0,
						math.floor(m0 + (cy + 1) * cw) - y0, 0)
			end
		end
	end
	return f
end

-- **A band: one seed, a whole frieze** ([SIGIL_ROUND], 2026-09-24).
--
-- The ornament on a slab's edge is a tile one voxel across, so it is
-- seen a hundred times along a wall and **the seam is the pattern**,
-- not an edge case. Everything here follows from that.
--
-- **The figure is a sigil laid across the tile's whole width**: seeded
-- cells, a fill, the continuity bias -- the same generator the orbs'
-- marks use, which is why a wall and an orb look like they come from
-- one hand. Mirrored about the tile's centre, which is what makes a
-- run of them read as ornament rather than as noise.
--
-- **Every tile of a wall shares one seam column**, drawn from the
-- wall's own seed and never touched by the growth. That is the whole
-- of what makes arbitrary motifs sit next to each other: a tile joins
-- its neighbour because both leave the tile in the same state. Holding
-- it by *excluding* the column from the growth rather than by writing
-- it back afterwards matters -- the write-back version joins just as
-- well and eats the figures doing it.
--
-- **A motif is held for two tiles, then the seed rolls.** Two is the
-- constant and the only one: the eye gets a repeat, which is what
-- makes a frieze a frieze, and then a change, which is what keeps a
-- wall from being wallpaper. After `cycle` motifs the run repeats, so
-- a wall's period is `cycle * 2` voxels -- eight or twelve -- which
-- [WORLD_UV] draws by giving the definition a uv_scale of that many
-- voxels and a texture that many tiles wide.
local BAND_HOLD = 2

-- One seed, every parameter. A wall says `band_style(seed_of(name))`
-- and has a frieze of its own that is nobody else's, without anybody
-- choosing numbers.
function M.band_style(seed)
	local r = rng(seed)
	-- **A seeded generator's first numbers are not random.** This is a
	-- linear congruential one, so the first output is an arithmetic
	-- function of the seed and neighbouring seeds give neighbouring
	-- values: over two thousand names the first pick came out 6 ninety
	-- times and 12 nine hundred, against four hundred each, while every
	-- draw after it was flat. Three throwaway draws is what the bias
	-- survives, and it costs nothing at boot.
	r(); r(); r()
	local function pick(t) return t[1 + math.floor(r() * #t)] end
	-- **A worm is the other thing a band can be** (user, 2026-09-24:
	-- the reference scene's "bordered squiggly worm"): one carved line
	-- wandering between two rules, rather than a field of cells. It
	-- has far less to say than the sigil -- with five rows there are
	-- only so many ways a worm can go -- so it is the minority kind
	-- and always bordered, the rules being what makes a wandering line
	-- read as ornament instead of as a crack.
	-- **Three kinds.** `sigil` is the grown field of cells; `worm` is
	-- the walked line, one seed and every voxel the same, which came
	-- out close enough to a Greek key to be called one; `wormb` is the
	-- same walk with its hand flipped on alternate tiles, which gives
	-- a band two sibling figures instead of one repeated.
	-- **Half and half** (user, 2026-09-24): the walked kinds were three
	-- in ten and a wall of the family read as mostly sigil. The two
	-- worms split their half evenly.
	local roll = r()
	local worm = roll < 0.5
	local kind = "sigil"
	-- **`wormb` is picked again** (2026-09-24): the seam it broke in
	-- about one seed in a hundred was the fallback that walks a worm
	-- which never reached the far column along its own row -- it wrote
	-- the two columns the seam lock had reserved, and that row is a
	-- different one under each hand. Measured over 600 styles a kind,
	-- four tiles each: every kind joins every row now.
	-- Off the same roll, so no seed's draw order changes and a wall
	-- keeps every sigil it had
	if worm then kind = (roll < 0.25) and "worm" or "wormb" end
	-- **Rails are the heavy end**, about 48% ink against 30, and a wall
	-- of them is a painted stripe. One in five.
	-- The worm carries its own border -- its outline is the carving --
	-- so it wants no rules around it.
	-- **Rules cost two rows, so they need rows to spare.** On the
	-- stretched lattice a sigil is four to six rows tall, and a rule
	-- top and bottom of a four-row band is half the face before the
	-- figure is drawn -- it took the ink to 57% where the fill asked
	-- for 38. They are offered only when the band has six.
	local rows_pick = pick({4, 5, 5, 6})
	local rails = (not worm) and rows_pick >= 6 and r() < 0.3
	-- **A worm needs room to wander.** The rules take the top and
	-- bottom row, so at three rows there is one row left and the worm
	-- is a straight line between two rules -- three filled rows, which
	-- is a solid bar and not ornament. Five rows leave it three, seven
	-- leave five; below that a worm has nothing to say.
	return {
		kind = kind,
		-- **A tile is square, so the two kinds want different
		-- lattices** ([WORLD_UV]: `uv_scale` is one number for both
		-- axes, so a voxel's face is a square of texture whatever the
		-- band is). A **worm is happy square** -- it needs nine rows
		-- to fold in and as many columns to fold along. A **sigil is
		-- not**: a square lattice at an even fill has no direction in
		-- it and comes out a chequer, so a sigil is drawn wide and
		-- short and stretched over the face, and the tall cells are
		-- what give the figure its upright stroke.
		-- **A worm's columns are even.** The mirror maps column C-1
		-- onto column 0, which is what carries the seam; with an odd
		-- count the centre column maps onto itself and `wormb`'s two
		-- hands stop agreeing where the groove can see across the
		-- join. Measured: every odd-column wormb broke 10 to 22 rows,
		-- every even one joined.
		cols = worm and pick({10, 12, 14}) or pick({12, 12, 14, 16}),
		-- **A worm wants nine rows at least** (user): the rules of the
		-- outline take one row above and one below every pass, so the
		-- passes sit two rows apart -- nine rows is four of them, and
		-- fewer than four is a line with a kink rather than a folded
		-- ribbon.
		-- **Four rows at least** (user, 2026-09-24): three cannot hold
		-- the shapes a figure needs -- with the fill at .5 a
		-- three-row band is a bar with notches out of it, whatever the
		-- seed. A worm's row count matches its columns, near enough.
		rows = worm and pick({9, 11, 13}) or rows_pick,
		-- The band fills the face: a slab's edge is one voxel of
		-- texture and a motif that does not fill it shows whichever
		-- slice of itself the slab's own height lands on.
		band_height = 1.0,
		-- **A stretched sigil wants half the fill a strip did.** The
		-- band used to sit in 62% of the tile, so a fill of .5 was
		-- about 30% of the face; filling the whole face at .5 is 50%
		-- of it, and at .6 three quarters -- a chequer with the stone
		-- gone. The worms count their fill against the half of the
		-- lattice the clearance rule leaves them, so theirs is
		-- unchanged.
		fill = worm and pick({0.45, 0.50, 0.55, 0.60})
				or pick({0.26, 0.30, 0.34, 0.38}),
		rails = rails,
		-- How many motifs before the run repeats; the period in voxels
		-- is this times BAND_HOLD. **A band with no rules to hold it
		-- together needs to repeat sooner to read as a pattern**, so
		-- the bare ones roll their seed after two to four motifs where
		-- a railed one can go four or six.
		-- **A worm does not cycle at all** (user, 2026-09-24). It is
		-- already a long figure that fills its tile, so a new seed
		-- every second voxel reads as a pattern being interrupted
		-- rather than as one that varies; the sigils are small and
		-- want the change. A worm's period is one voxel, so its
		-- texture is one tile wide.
		cycle = worm and 1
				or (rails and pick({4, 6}) or pick({2, 3, 4})),
		hold = BAND_HOLD,
		bias = 0.8,
		seed = seed,
	}
end

-- The `i`th tile of that wall, as a height field. `i` is the voxel's
-- own index along the run, so a mesher can ask for it directly.
function M.band(size, style, i)
	local C, R = style.cols, style.rows
	local half = math.ceil(C / 2)
	local which = math.floor((i % (style.cycle * style.hold)) / style.hold)
	local r = rng(style.seed + which * 7919)
	local on, n = {}, 0
	local want = math.floor(half * R * style.fill + 0.5)
	local function K(cx, cy) return cy * half + cx end
	local function touches(cx, cy)
		for _, d in ipairs({{-1, 0}, {1, 0}, {0, -1}, {0, 1}}) do
			local nx, ny = cx + d[1], cy + d[2]
			if nx < 0 then nx = 0 end
			if nx >= half then nx = half - 1 end
			if ny >= 0 and ny < R and on[K(nx, ny)] then return true end
		end
		return false
	end
	-- the shared seam, a contiguous run of rows so it reads as a link
	-- between neighbours rather than as a comb
	local sr = rng(style.seed)
	sr(); sr(); sr()
	local alen = 1 + math.floor(sr() * math.max(1, R - 1))
	local a0 = math.floor(sr() * (R - alen + 1))
	for cy = a0, a0 + alen - 1 do on[K(0, cy)] = true; n = n + 1 end
	while n < want do
		local pool, grow = {}, r() < style.bias
		for cx = 1, half - 1 do
			for cy = 0, R - 1 do
				if not on[K(cx, cy)] and ((not grow) or touches(cx, cy)) then
					pool[#pool + 1] = {cx, cy}
				end
			end
		end
		if #pool == 0 then
			for cx = 1, half - 1 do
				for cy = 0, R - 1 do
					if not on[K(cx, cy)] then pool[#pool + 1] = {cx, cy} end
				end
			end
		end
		if #pool == 0 then break end
		local p = pool[math.floor(r() * #pool) + 1]
		on[K(p[1], p[2])] = true
		n = n + 1
	end
	local g = {}
	for cy = 0, R - 1 do
		for cx = 0, C - 1 do
			local sx = (cx < half) and cx or (C - 1 - cx)
			g[cy * C + cx] = on[K(sx, cy)] and true or false
		end
	end
	if style.kind ~= "sigil" then
		-- **The worm** (user, 2026-09-24, the reference scene's): one
		-- line that squiggles inside a tile or two, **running backwards
		-- for short distances** rather than marching across, and
		-- **carved as its own outline** -- the worm's body stays
		-- uncut stone and a groove is cut around it, which is what
		-- makes it read as something lying on the face rather than as
		-- a channel in it.
		--
		-- A self-avoiding walk on the left half's cells, weighted
		-- towards the right so it arrives, with up, down and back all
		-- possible so it wanders on the way. It starts on the seam
		-- column at the shared row, so one tile's worm meets the next
		-- one's, and is mirrored at the centre like everything here.
		-- straight over a turn over a reversal; W_ON is the bonus a
		-- rightward step gets, which is the worm's only reason to
		-- arrive anywhere
		-- straight, the turn that keeps the hand, the turn against it,
		-- a reversal; and how often the hand changes
		local W_STRAIGHT, W_CURL, W_TURN, W_REVERSE = 6, 3, 1, 1
		local P_FLIP = 0.04
		local P_SPIRAL = 0.22
		local W_ON, W_REVISIT, W_PACK = 1, 1, 0
		local SEAM_LOCK = 3
		local path = {}
		local function P(cx, cy) return cy * half + cx end
		-- **The worm keeps a row clear above and below it**, because
		-- the outline is a cell wide like everything else and has to
		-- go somewhere. At five rows the worm has three to wander in.
		local lo, hi = 1, R - 2
		local cx, cy = 0, math.max(lo, math.min(hi, a0))
		path[P(cx, cy)] = true
		local steps, reach = 0, 0
		local ldx, ldy = 1, 0
		-- **Alternate tiles start on the other hand** (user,
		-- 2026-09-24): the worm does not cycle its seed, so without
		-- this every voxel is the same figure exactly. Flipping which
		-- way it first wants to curl is the smallest change that can
		-- be made to a walk -- the seed, the lattice and every weight
		-- are the same -- and the walk diverges from its first turn,
		-- so the band alternates between two worms that are plainly
		-- siblings. A run of it repeats every two voxels rather than
		-- every one.
		local spin = (r() < 0.5) and 1 or -1
		if style.kind == "wormb" and i % 2 == 1 then spin = -spin end
		-- **Arriving is not stopping.** The mirror copies column
		-- half-1 to column half, so the two are identical neighbours
		-- and the worm joins itself at the centre the moment it
		-- *touches* the far column -- it does not have to end there.
		-- Stopping on arrival is what kept the worm to one pass across
		-- a nine-row band; it walks its whole budget now and fills.
		-- **How long the worm is, is `fill`** -- the same knob the
		-- sigils use, which a worm ignored until now. Counting *steps*
		-- does not control density: the walk spends them revisiting
		-- once it runs out of legal ground, so a longer budget only
		-- fills the lattice as far as the clearance rule allows and
		-- every worm comes out the same weight. Counting the cells it
		-- has taken does control it.
		--
		-- The lattice is about half occupiable, a pass and a gap, so
		-- the target is scaled against that rather than against the
		-- whole.
		local target = math.floor(half * (hi - lo + 1) * style.fill * 0.55)
		local taken = 1
		while steps < half * R * 8 and taken < target do
			steps = steps + 1
			local moves = {}
			-- **The first cells are the same whichever hand it holds.**
			-- A tile draws its groove from its own wrapped edge, so it
			-- assumes its neighbour begins the way it does; `wormb`
			-- flips the hand, the two walks part company at the first
			-- turn, and the two outlines disagree across the seam --
			-- 77 rows of 224 joined before this. Walking straight out
			-- of the seam for two cells, and never writing those
			-- columns again, makes the tile's first two columns
			-- identical under either hand -- which is as far across
			-- the seam as an outline can see.
			local locked = steps < SEAM_LOCK
			-- right is likely, up and down half as likely, back a
			-- quarter: a squiggle, not a march
			-- **The worm may walk back along itself.** A strictly
			-- self-avoiding walk cannot turn round: to go back it has
			-- to leave a row free to come back through, so every
			-- reversal costs it a switchback. Letting it re-enter its
			-- own trail lets it do a 180 inside a cell and set off
			-- again, which is how a real squiggle is drawn. A revisit
			-- adds nothing to the figure -- the cell is already cut --
			-- so it is free, and it is weighted low so the worm
			-- prefers new ground when there is any.
			-- **A new pass keeps a cell clear of the old one.** The
			-- groove is a cell wide, so two passes lying side by side
			-- leave it nowhere to go and the worm welds itself into a
			-- slab. A fresh cell is taken only when it touches the
			-- worm at the cell being stepped from and nowhere else.
			--
			-- **Four neighbours, not eight.** Eight was tried and the
			-- worm could only go straight: a path is contiguous, so
			-- after one turn the cell before last is always a diagonal
			-- of the next one, and every turn was refused. Diagonal
			-- touching is what a fold looks like and it is allowed.
			local function clear(nx, ny)
				for _, d in ipairs({{-1, 0}, {1, 0}, {0, -1}, {0, 1}}) do
					local ax, ay = nx + d[1], ny + d[2]
					if not (ax == cx and ay == cy) and ax >= 0 and ax < half
							and ay >= 0 and ay < R and path[P(ax, ay)] then
						return false
					end
				end
				return true
			end
			-- **Walking back over itself is a last resort, not a
			-- move.** With a revisit in the same pool as fresh ground
			-- the worm takes its own trail whenever the weighting
			-- happens to favour it, and a curl that wanted to close
			-- goes back the way it came instead. Fresh cells are the
			-- pool; the trail is only offered when the pool is empty.
			local back = {}
			local function try(dx, dy, w)
				local nx, ny = cx + dx, cy + dy
				if nx >= 0 and nx < half and ny >= lo and ny <= hi then
					if path[P(nx, ny)] then
						for _ = 1, W_REVISIT do back[#back + 1] = {nx, ny} end
					elseif clear(nx, ny) then
						for _ = 1, w do moves[#moves + 1] = {nx, ny} end
					end
				end
			end
			-- **A lazy worm is a straight one.** Weighting the step
			-- towards the right gets it across the tile and nothing
			-- else; the squiggle is in the turns, so going back is
			-- worth as much as going on and the verticals are worth
			-- more than either. Self-avoidance does the rest: to come
			-- back on itself the worm has to change row first, which
			-- is what makes a switchback instead of a wiggle.
			-- **Momentum, so the worm draws strokes and not a
			-- staircase.** Weighting the four directions the same way
			-- every step makes it alternate -- right, down, right,
			-- down -- which is a diagonal drawn in single cells and
			-- reads as a zigzag rather than as a carved line. Carrying
			-- the last direction and preferring it turns the same
			-- walk into runs that meet at right angles, which is what
			-- a meander is. The rightward bonus is what gets it across
			-- the tile; without it a worm with momentum happily runs
			-- up and down for ever.
			-- **A spiral is a worm that keeps turning the same way**
			-- and never takes the easy way back. Holding a hand --
			-- clockwise or widdershins -- and preferring the turn that
			-- matches it curls the walk into itself; the clearance
			-- rule stops the curl one cell short of closing, which is
			-- what leaves the groove a way out and the spiral its eye.
			-- The hand flips now and then, so a band gets a coil, an
			-- unwinding and another coil the other way rather than one
			-- endless scroll.
			--
			-- **This only draws spirals because a revisit is a last
			-- resort** (user, 2026-09-24). With the trail in the same
			-- pool as fresh ground the worm walks back the way it came
			-- whenever the weights happen to favour it, and a curl
			-- that wanted to close unwinds instead. A spiral built as
			-- an explicit figure -- runs of 3, 3, 2, 2, 1 laid out and
			-- checked before committing -- was written first and then
			-- deleted: with the revisit demoted the two sheets came out
			-- **byte-identical**, so the construction was fifty lines
			-- that never fired.
			if r() < P_FLIP then spin = -spin end
			for _, d in ipairs({{1, 0}, {0, -1}, {0, 1}, {-1, 0}}) do
				local w
				if d[1] == ldx and d[2] == ldy then
					w = W_STRAIGHT
				elseif d[1] == -ldx and d[2] == -ldy then
					w = W_REVERSE
				elseif d[1] == -ldy * spin and d[2] == ldx * spin then
					w = W_CURL
				else
					w = W_TURN
				end
				if d[1] == 1 then w = w + W_ON end
				if locked and not (d[1] == 1 and d[2] == 0) then w = 0 end
				-- and the seam's own columns are not written again
				-- after that: coming back into column 1 later is what
				-- made the two hands differ where the outline can see
				if not locked and cx + d[1] <= 2
						and not path[P(cx + d[1], cy + d[2])] then
					w = 0
				end
				if w > 0 then
					-- **Pack tight.** Of the moves left, prefer the one
					-- with the least room around it: a cell whose own
					-- neighbours are already the worm, or the band's edge,
					-- is a cell that fills a gap rather than opening a new
					-- one. It is the same instinct that solves a knight's
					-- tour -- go where the choices are fewest -- and here
					-- it makes the worm fold back into its own space
					-- instead of sprawling along the band.
					local nx, ny = cx + d[1], cy + d[2]
					local blocked = 0
					for _, e in ipairs({{-1, 0}, {1, 0}, {0, -1}, {0, 1}}) do
						local ax, ay = nx + e[1], ny + e[2]
						if ax < 0 or ax >= half or ay < lo or ay > hi
								or path[P(ax, ay)] then
							blocked = blocked + 1
						end
					end
					try(d[1], d[2], w + W_PACK * blocked)
				end
			end
			if #moves == 0 then moves = back end
			if #moves == 0 then break end
			local m = moves[math.floor(r() * #moves) + 1]
			ldx, ldy = m[1] - cx, m[2] - cy
			cx, cy = m[1], m[2]
			if not path[P(cx, cy)] then taken = taken + 1 end
			path[P(cx, cy)] = true
			if cx > reach then reach = cx end
		end
		if reach < half - 1 then
			-- nothing reached the far column, so the worm is walked
			-- there along its own row: a tile that does not touch the
			-- seam's other end is a tile whose figure stops mid-wall.
			-- **It starts past the seam lock**: the row it ends on is a
			-- different one under each hand, and writing it into the
			-- columns the lock reserved is the whole of `wormb`'s
			-- broken seam -- 29 styles in 600 before this, none after
			-- (2026-09-24). Those columns already carry the straight
			-- walk out of the seam, which is what joins.
			for x = SEAM_LOCK, half - 1 do path[P(x, cy)] = true end
		end
		local body = {}
		for cyy = 0, R - 1 do
			for cxx = 0, C - 1 do
				local sx = (cxx < half) and cxx or (C - 1 - cxx)
				body[cyy * C + cxx] = path[P(sx, cyy)] and true or false
			end
		end
		-- **The carving is the outline, a cell wide**: the worm's own
		-- cells stay uncut stone and the cells touching it are cut, so
		-- the groove is drawn at the same size as every other figure
		-- in this file and a worm sits among them on one sheet.
		-- Adjacency wraps in x, so a worm's groove meets the next
		-- tile's instead of sealing the worm in at the seam.
		g = {}
		for cyy = 0, R - 1 do
			for cxx = 0, C - 1 do
				if not body[cyy * C + cxx] then
					for _, d in ipairs({{-1, 0}, {1, 0}, {0, -1}, {0, 1},
							{-1, -1}, {1, -1}, {-1, 1}, {1, 1}}) do
						local nx = (cxx + d[1]) % C
						local ny = cyy + d[2]
						if ny >= 0 and ny < R and body[ny * C + nx] then
							g[cyy * C + cxx] = true
						end
					end
				end
			end
		end
	end
	if style.rails then
		for cx = 0, C - 1 do g[0 * C + cx] = true; g[(R - 1) * C + cx] = true end
	end
	-- **Cell edges from the fraction, not from floor(size/cols)**: a
	-- count that does not divide the texture leaves a strip of bare
	-- stone at the tile's right -- ten columns of nine pixels in
	-- ninety-six is ninety -- and those six pixels break every seam
	-- they touch.
	local f = field(size)
	-- How much of the tile's height the band fills. A frieze is a strip
	-- on a face, so it is 0.62 by default; a square tile wants 1.
	local bh = math.floor(size * (style.band_height or 0.62))
	local top = math.floor((size - bh) / 2)
	for cy = 0, R - 1 do
		for cx = 0, C - 1 do
			if g[cy * C + cx] then
				local x0 = math.floor(cx * size / C)
				local y0 = top + math.floor(cy * bh / R)
				box(f, x0, y0, math.floor((cx + 1) * size / C) - x0,
						top + math.floor((cy + 1) * bh / R) - y0, 1)
			end
		end
	end
	return f
end

-- **The wall's own material** (user, 2026-09-22): a matte finished,
-- clean cut stone surface with large patches of mineral variation. Not
-- rough and not carved -- the "knobby" of the first reading is the
-- coursing of the cut blocks, not a bumpy texture. So the height field
-- is flat but for the block seams, and the only real variation is slow,
-- large-scale mineral blotching in the albedo.
--
-- It is meant to be seen across many voxels at once, which is what
-- uv_scale is for ([WORLD_UV]): at one repeat per voxel a patch larger
-- than 45 cm cannot exist and the biggest surface in the room reads as
-- a grid of identical stamps.
--
-- simplified: the blotches are one octave of value noise. Two or three
-- would break up the remaining regularity; one is enough to tell
-- whether the wall reads as stone, which is what it is for now.
local function value_noise(size, cells, r)
	-- A coarse grid of random values, read back bilinearly: slow, large
	-- patches rather than texel noise
	local g = {}
	for i = 0, (cells + 1) * (cells + 1) - 1 do
		g[i] = r()
	end
	local function at_cell(cx, cy)
		return g[(cy % (cells + 1)) * (cells + 1) + (cx % (cells + 1))]
	end
	local f = field(size)
	local step = size / cells
	for y = 0, size - 1 do
		for x = 0, size - 1 do
			local fx, fy = x / step, y / step
			local x0, y0 = math.floor(fx), math.floor(fy)
			local tx, ty = fx - x0, fy - y0
			-- Smoothstep, so the patches have no grid in their edges
			tx = tx * tx * (3 - 2 * tx)
			ty = ty * ty * (3 - 2 * ty)
			local a = at_cell(x0, y0) + (at_cell(x0 + 1, y0) -
					at_cell(x0, y0)) * tx
			local b = at_cell(x0, y0 + 1) + (at_cell(x0 + 1, y0 + 1) -
					at_cell(x0, y0 + 1)) * tx
			put(f, x, y, a + (b - a) * ty)
		end
	end
	return f
end

function M.wall(size, seed, opts)
	opts = opts or {}
	local r = rng(seed)
	-- The coursing: horizontal beds every course_h texels, and the
	-- vertical joints offset by half a block course to course, which is
	-- what dressed stone does and what keeps the seams from lining up
	local h = field(size, 0.72)
	local course = opts.course or math.floor(size / 6)
	local block = opts.block or math.floor(size / 3)
	for y = 0, size - 1 do
		local row = math.floor(y / course)
		local bed = (y % course) == 0
		for x = 0, size - 1 do
			local jx = (x + (row % 2) * math.floor(block / 2)) % block
			if bed or jx == 0 then
				-- A seam is a narrow recess, which is all the relief
				-- this surface has
				put(h, x, y, 0.30)
			end
		end
	end
	-- The mineral patches, in the albedo only: the inlay mask carries
	-- them and maps() tints by it
	local blotch = value_noise(size, opts.cells or 4, r)
	local inlay = field(size)
	for i = 1, size * size do
		-- A patch is where the noise is high, with a soft edge so it
		-- reads as mineral rather than as a stain
		local v = blotch[i]
		inlay[i] = v > 0.58 and math.min(1, (v - 0.58) * 3.2) or 0
	end
	return h, inlay
end

-- The maps, derived and not authored.
--
-- simplified: the relief goes into the **albedo** as a shade as well as
-- into the normal map. Urho3D's shipped Box.mdl and Sphere.mdl carry no
-- vertex tangents, so a normal map alone would do nothing on them; the
-- baked shade is what makes the ornament visible either way. The upgrade
-- is tangents on the models the room actually uses, at which point the
-- shade can come out.
-- simplified: no roughness map -- the material's own Roughness uniform
-- stands for the whole face. The upgrade is a spec map with roughness in
-- its red channel, which is where Urho3D's PBR shaders read it.
function M.maps(magic, h, inlay, opts)
	opts = opts or {}
	local size = h.size
	-- A strip is wider than it is tall ([SIGIL_ROUND]); a square field
	-- says nothing and is its own height
	local rows = h.rows or size
	local base = opts.base or magic.Color(0.30, 0.30, 0.33, 1)
	local tint = opts.inlay or magic.Color(0.34, 0.16, 0.42, 1)
	local relief = opts.relief or 0.45
	local diff = magic.Image:new()
	local norm = magic.Image:new()
	-- **Built as bytes and handed over once** ([ROOM_BOOT], 2026-09-24):
	-- a 128-pixel tile is sixteen thousand pixels and the room makes
	-- three of them before it can mesh, each written twice -- the
	-- albedo and the normal -- a pixel at a time through the sandbox.
	-- image_set_data takes the whole buffer; where it is missing (this
	-- file runs under plain lua for its own sheets) the old path stays.
	local bulk = magic.image_set_data ~= nil
	local dpx, npx = {}, {}
	if not bulk then
		assert(diff:SetSize(size, rows, 3), "Image:SetSize")
		assert(norm:SetSize(size, rows, 3), "Image:SetSize")
	end
	local function byte(v)
		v = math.floor(v * 255)
		if v < 0 then v = 0 elseif v > 255 then v = 255 end
		return v
	end
	for y = 0, rows - 1 do
		for x = 0, size - 1 do
			-- The normal, by Sobel on the height
			local nx = (at(h, x - 1, y) - at(h, x + 1, y)) * (opts.strength or 3)
			local ny = (at(h, x, y - 1) - at(h, x, y + 1)) * (opts.strength or 3)
			local l = math.sqrt(nx * nx + ny * ny + 1)
			if bulk then
				npx[#npx + 1] = string.char(byte(nx / l * 0.5 + 0.5),
						byte(ny / l * 0.5 + 0.5), byte(1 / l * 0.5 + 0.5))
			else
				norm:SetPixel(x, y, magic.Color(nx / l * 0.5 + 0.5,
						ny / l * 0.5 + 0.5, 1 / l * 0.5 + 0.5, 1))
			end
			-- The albedo: the base, tinted where the inlay is, shaded by
			-- the relief as if lit from the upper left
			local c = at(inlay, x, y) > 0.5 and tint or base
			local s = 1 - relief + relief * (0.5 + 0.5 * (nx - ny) / l +
					0.35 * at(h, x, y))
			if bulk then
				dpx[#dpx + 1] = string.char(byte(c.r * s), byte(c.g * s),
						byte(c.b * s))
			else
				diff:SetPixel(x, y, magic.Color(c.r * s, c.g * s, c.b * s, 1))
			end
		end
	end
	if bulk then
		magic.image_set_data(diff, size, rows, 3, table.concat(dpx))
		magic.image_set_data(norm, size, rows, 3, table.concat(npx))
	end
	return diff, norm
end

-- The generator's own check, run at boot and said in one line: these
-- are patterns, so what can be asserted is that each one is a pattern --
-- that it covers a sane share of its field, that the sigil is symmetric
-- because it is mirrored twice, and that the socket field has both a
-- face and a recess in it. A generator that quietly returns a flat field
-- would pass an eye on a dark slab and fail here.
function M.self_check(size)
	size = size or 128
	local function coverage(f)
		local n = 0
		for i = 1, f.size * f.size do
			if f[i] > 0.5 then n = n + 1 end
		end
		return n / (f.size * f.size)
	end
	local mh = M.meander(size, {units = 3, depth = 2})
	local mc = coverage(mh)
	assert(mc > 0.03 and mc < 0.45,
			"the meander covers " .. mc .. " of its field")
	local sh = M.sockets(size, {cells = 3, depth = 2, seed = 7})
	local sc = coverage(sh)
	assert(sc > 0.15 and sc < 0.95,
			"the socket field covers " .. sc)
	-- Both a face and a recess: a socket is low where the face is high
	local low = false
	for i = 1, sh.size * sh.size do
		if sh[i] < 0.1 then low = true break end
	end
	assert(low, "the socket field has recesses")
	local gh = M.sigil(size, M.seed_of("buildat.example.org:30000"), 4)
	local off = 0
	for y = 0, size - 1 do
		for x = 0, size - 1 do
			if M.at(gh, x, y) ~= M.at(gh, size - 1 - x, y) then
				off = off + 1
			end
		end
	end
	assert(off == 0, "the sigil is mirrored, " .. off .. " texels differ")
	-- And a different address is a different sigil, which is the whole
	-- point of seeding it with one
	local other = M.sigil(size, M.seed_of("elsewhere.net:30000"), 4)
	local same = 0
	for i = 1, size * size do
		if gh[i] == other[i] then same = same + 1 end
	end
	assert(same < size * size * 0.95,
			"two addresses draw two sigils, " .. same .. " texels shared")
	return string.format("ornament ok: meander %.0f%% of its field, " ..
			"sockets %.0f%%, the sigil mirrored and %.0f%% unlike another " ..
			"address's", mc * 100, sc * 100, 100 - same / (size * size) * 100)
end

return M
