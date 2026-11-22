-- Buildat: builtin/kit/client_lua/move.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- [KIT] stage 4h: the movement interface's world, the same file on both
-- sides: the client predicts with it (controls.lua) and the server's box
-- steps with it (kit.cpp loads it into box.c's Lua, request "L"). Plain
-- Lua with + - * /, floor and sqrt only (the box has no libm), so both
-- sides compute the same bits; sin, cos and atan2 are its own.
--
-- A movement type (builtin/kit/types/walker.lua...) has
--   movement = {body = {r = half width, h = height, eye = eye height},
--     camera = "first_person"|"chase" (a vehicle's), camera_distance = a
--     chase view's metres behind (else kit/controls' distance), camera_up =
--     metres its target is raised, touch = "stick"|"tap"|"drive",
--     touch_buttons = {{"Fire", "jump"}...}: the touch bar's buttons, each
--     held while pressed as that input (jump or down), for the default Jump,
--     [KIT_TOUCH_THUMBS] touch_axes (experimental, [KIT_API_1]: it may
--     change in any release) = {{"Left", "r", -1}, {"Right", "r", 1}}:
--     a stack at the lower left beside the stick (top to bottom), each holding
--     that input (f or r) at that value while pressed (full steering taps),
--     [KIT_PLAY_HINTS] help = {{"{key:forward}/{key:back}", "gas, brake",
--     "f"}...} and touch_help alike: an app's help line in play (keys,
--     what, the input: f, r, jump or down), each item gone once its input
--     is used (controls.lua's kit.movement_help; without them the app's own)}
--   step = function(s, i, dt, w, p) ... end
-- [KIT_PLANE] stage 4, a movement of a builder's own (a custom type) has more:
--   movement.raw_keys = true: the side camera's keys as they are (f forward
--     and back, r right and left: a bike's throttle and lean), not a walk
--     along the plane
--   math in its file is M.math on both sides (controls.lua and box.c's define
--     run the file with it): floor, ceil, sqrt, abs, fmod, min, max, huge, pi
--     and this file's sin, cos, atan, atan2, [KIT_SMALL_PIECES] exp and pow,
--     the same bits there; no random (x ^ y is not the same bits: math.pow)
--   s.events = {"name" | {"name", value}...} set by a step (nil before each,
--     MAX_EVENTS a batch): the server's steps' are outputs of the movement's
--     component on the app root (its `outputs`), as by the body's player; the
--     client's own steps set them too, for its draw to show them at once
--   s.pose = {n...} (8 at most): what the other clients' draw gets of it;
--     [KIT_MOVE_DRAW] movement.pose = {"name"...} (8 at most, in slot order)
--     names the slots: a step may then write s.pose by name ({a = 1, dir =
--     -1}) or by index, kept as the numbers in slot order (a slot left out 0;
--     the next step reads it back by index), the wire's as ever; a draw reads
--     s.pose by name and by index alike (M.pose_view)
-- [KIT_ZONE_SHAPES] How the server's zones (a type's zone: on_enter, on_leave,
-- who is in it) meet the body, any movement's:
--   s.spheres = {{x, y, z, r}...} set by a step (kept in the state as the rest):
--     spheres from s.pos (the feet) along the world's axes, a step turning them
--     as it turns (in a side view's plane circles: a bike's wheels and head);
--     8 at most (the rest unmet), each within 16 m of the feet, r 0.01 to 8, a
--     bad one unmet. The editor's Front view draws the builder's own body's
--   else movement.zone = "box": its body box (body.r either side of the feet,
--     body.h up; kit/walker's and kit/click_to_move's)
--   else its point (s.pos, a cell's middle up: what zones met before)
--   A seat's holder is met by its point (the seat's place)
--   a step past box.c's STEP_CAP Lua instructions errs "too slow": the body
--     stops (the component's Log says it) till put again or the next version;
--     put_type steps a new version once (an empty world) and refuses it so,
--     the version before kept. Three client steps past 50 ms in a row turn
--     its prediction off
--   draw = function(s, node, yaw, p) in its .client.lua: each frame, each body
--     drawn (players.lua): node at its feet as drawn (no turn; its children
--     the hook's), s this client's predicted state or another's {pos, pose,
--     vars}, yaw the own body's as drawn between its steps (degrees); the
--     humanoid not drawn. [KIT_MOVE_DRAW] p the movement's parameters (the
--     step's p: a wheel's size is a parameter, never a constant copied into
--     the client part); s.vars an other's public body vars (c:body_var's
--     {public = true}; this client's own body has all its own); node made
--     anew when the draw function changes (the client part put again): what
--     an older version made under it is gone, no versioned child names
-- s its state (s.pos the body's bottom middle {x, y, z}, s.vel; the rest
-- its own), changed in place; [KIT_BODY_VARS] s.vars (nil: none) the values
-- the server's components set on this body (c:body_var(by, key, value)), read
-- only: in the state the server sends, so the client's re-steps have the
-- server's (a step's change to them is undone at the server's next state);
-- [KIT_MOVE_DRAW] one set {public = true} is in every client's draw too (s.vars,
-- the others' bodies' as well: on the body's node, sent as it changes);
-- A put (a teleport, a respawn, a seat taken or left, out of the world) starts
-- the state afresh on the server and the client alike: s holds pos and yaw
-- (and vars), its own fields gone, so a step keeping a place of its own (a
-- bike's frame) starts over from s.pos; a knock back and a change of its
-- parameters (c:speed, c:set_param) keep it. A hazard that must react at once
-- belongs in the step (a surface it meets: w:circle's, w:under's info), not in
-- a server zone: a zone's on_enter is the server's, a round trip late on the
-- client, which then rewinds;
-- i this step's input: f (forward, -1...1),
-- r (right), yaw (the camera's, degrees from +z toward +x), jump (0/1),
-- go (0/1: a target), tx, ty, tz (where to go), [KIT_CLIENT_REACT] (10)
-- out_of_play (true while the player is out of play: dead and waiting to
-- respawn, in a kit/lobby's lobby or result; its keys none then; nil in play;
-- c:speed(by, 0) stays the freeze), [KIT_AUTO_JUMP] auto (1 while the
-- movement's auto_jump param is on for this client: w:walk's auto, up a
-- one-voxel step without Jump; else nil), [KIT_MOVE_DRAW] speed (c:speed's
-- factor for the body as it is now: 1, 0 frozen; a seated player's theirs, a
-- steered vehicle's 1, a driving bot's its own; the `speed` param is scaled
-- by it on the body's own movement, not a seat's); dt seconds; p its
-- parameters; w the world. [KIT_API_1] (item 4) Kit API 1's w is these 11
-- methods, w:cell, w:walk, w:move, w:ray, w:down, w:under, w:contacts,
-- w:circle, w:segment, w:unbury and ([KIT_SMALL_PIECES]) w:resolve_circle,
-- and the fields w.sin, w.cos, w.atan2,
-- w.sqrt, w.PI, w.plane, w.horizontal and w.bodies (below; atan is the
-- file's math.atan). The other 18 methods a step can reach (W's:
-- w:pose_at, deck_velocity, height, ground_max, sweep, sweep_turned,
-- sweep_polys, shed, blocked, pushed, slide, ray_objects, floor_at, hold,
-- plane_edges, frame_world, walk_on, walk_flat) and the other fields
-- (w.polys, w.floors, w.boxes, w.cache...) are internal: the official ones
-- use them, they may change in any release, and publishing a game whose
-- step calls one (w:<name>( in its file) warns (kit.cpp's EXPERIMENTAL).
--   w:cell(i, j, k) -> info or nil (air, and a liquid: solids only): the
--     voxel centred on i, j, k
--   w:walk(s, b, wx, wz, jump, dt, p, auto): a character's step, s.frame below
--   w:move(b, dx, dy, dz, step) -> dx, dy, dz moved, hits {x, y, z}
--     (hit sides: -1, 0 or 1): the body b = {x, y, z, r, h} swept along
--     y, then x and z, up a step of `step` where blocked, and onto the
--     ground's slope up to b.slope (tan of the slope limit)
--   w:ray(ox, oy, oz, dx, dy, dz, len) -> t, info, nx, ny, nz
--   w:down(x, y, z, len) -> how far down the first solid is, its info
--   w:under(x, y, z) -> the info of what is under the point (0.6 down)
--   w:contacts(b) -> {{info, nx, ny, nz}...} what touches the body
--   w:unbury(pos, b) -> true when lifted: a body b = {r, h} buried by an edit
--     lifted to the lowest free place over it (up to 64 m over its feet with its middle in the solid, else its height and a cell;
--     never sideways), pos {x, y, z} its bottom middle changed (kit/ball's
--     and kit/car's step first)
--   w.sin, w.cos, w.atan2, w.sqrt, w.PI
-- info = {solid = true, friction = n (1), surface = "<tag>"}: a voxel's
-- (its type's `friction` and `surface` where it has them, else 1 and its
-- name without the author), an object's ("object"), the heightmap's
-- ("ground") or a cell not loaded ("unknown", solid; air over a
-- heightmap, [KIT_HM_FREE]) or a heightmap's edge ("edge").
-- [KIT_WALKER_FRAME] A walker on a free voxel object steps in the object's
-- frame, where its boxes are flat: s.frame the object's entity id, s.at the feet
-- there, s.vel its velocity there (s.pos stays the feet in the world, kept up
-- each step). Gravity is the world's turned in: past slope_limit the deck slides.
-- It enters on landing on an object's top (W:walk's end) and leaves by jumping,
-- by nothing under it, or by the world's floor under it (W:walk_on).
-- [KIT_MOVING_OBJECTS] A free object's pose can be a function of the shared time,
-- so no pose is ever sent: each input carries the time it was stepped at (i.t, ms),
-- M.steps puts the world's objects where they are at that time on both sides, and a
-- body in a frame is carried by s.at being local. The motion's parameters are
-- kit/wave's (M.wave); a row has its own and those of the moving objects it
-- is under as links, each in the world at rest (M.turned).
-- [KIT_PLANE] w.plane (kit/controls' plane "vertical": the spawn's depth, a whole z;
-- nil: none): x right, y up, the camera on the -z side looking +z. M.steps holds the
-- body at that z after each step (both sides: the bits agree); W:walk and W:move go
-- nowhere across it. The 2D queries, in the plane at z (default w.plane, else 0), what
-- a movement of its own collides with:
--   w:circle(x, y, r, z) -> {{depth = d, nx = , ny = , info = }...}: what overlaps
--     the circle, the deepest first, each with its normal out toward the circle's
--     middle and how far in it reaches ({}: free)
--   w:segment(x0, y0, x1, y1, z) -> t (0...1 of the way), nx, ny, info: the first
--     solid the segment meets, the normal out of it toward the start (nil: none)
--   [KIT_SMALL_PIECES] w:resolve_circle(x, y, r, vx, vy, e, mu, z) -> x, y, vx,
--     vy, hits: a circle moving at vx, vy (a wheel, a ball) pushed out of the
--     deepest of w:circle's hits, its speed into it gone and e (0...1) of it
--     bounced back, its speed along it slowed by friction (at most mu times the
--     hit's info.friction times the push back; enough stops its sliding), again
--     while another is still in (4 rounds at most); hits each round's w:circle
--     hits in turn (one may be there twice), each pushed out of with vn, the
--     speed into it before (negative: it came in). crag_bike's wheels use it
--     with mu 0 and their own tyre on the hits' vn
-- They meet the voxels of the plane's layer (a whole cell's side against a solid
-- neighbour is no surface: nothing catches on a floor's seams), the shapes' and the
-- solid looks' boxes through z, the heightmap's profile along z and the polygons'
-- outlines (W:plane_edges); the segment the free objects too (W:ray's).
-- simplified: the circle meets no free voxel object
-- [KIT_TOP_DOWN] (1) w.horizontal (kit/controls' plane "horizontal"): w.plane is then a
-- whole y, the middle of the spawn's cell; the body's feet are held at w.plane - 0.5
-- (that cell's bottom, standing on the cell under it), its speed up none, and W:move
-- and W:walk go nowhere up or down: a walker there has no gravity and no jump, always
-- on its floor (W:walk_flat; its s.friction and s.surface w:under's). The 2D queries
-- are then in the level plane at that y (z above: the slice's y, default w.plane):
-- their x, y the world's x and z, nx, ny the normal's x and z, a circle meeting the
-- voxels of that layer, the boxes through that y and the outlines of the polygons
-- lying flat (stage 3's prisms with their depth up) that span it.
-- simplified: in a horizontal plane the heightmap is no 2D edge (W:move still meets
-- it), nor is a standing polygon (its slice there is the upgrade)
-- [KIT_TOP_DOWN] (8) Bodies pass through each other unless a movement asks:
-- movement.bodies = true (its type's declaration) in a level plane, its w:circle
-- meets the other players' bodies as circles (w.bodies, t.bodies {{x, z, r, vx, vz,
-- by}...}: kit.cpp's bodies_lit() for the server's step, the others' last known
-- places on a client, players.lua's others_bodies()), info.body their by, info.vel
-- {vx, vz}. Each step pushes its own body out of them (half the depth: the other's
-- step does the rest), the server deciding. simplified: a correction on contact (a
-- client's others are a round trip old); W:segment and W:move meet no bodies
-- [KIT_PLANE] stage 3: kit/polygon's look ("polygon": its points {{x, y}...} in its
-- own x and y, extruded `depth` along its own z round its place) lying flat to the
-- world's x and y (its yaw 0 or 180, any roll) is a prism (M.look_poly, w.polys):
-- W:sweep meets its sides along x and y (each edge one-sided: a body coming at it
-- from outside; a corner of the body along the move onto an edge, an edge's end onto
-- the body's face) and its faces along z, W:blocked its area, W:plane_edges its
-- outline, W:down its tops. W:move climbs an edge as the body's slope lets (b.slope,
-- the heightmap's), else it is a wall: no step up it. With the plane on one is met
-- where it spans the plane's z; one at another depth is background or foreground.
-- An edge's info is {solid, friction, surface, nx, ny: its normal out}: [KIT_CLIENT_REACT]
-- (5) its look's surface (a tag, "polygon" by default) and friction (1; 0...10),
-- kit/polygon's params so named, the same in a step on both sides: a step reacts to
-- "spikes" or "ice" itself.
-- [KIT_TOP_DOWN] (2) one lying flat (its own z along the world's y: pitch 90 or -90,
-- any yaw and roll; pitch 90 has its points' x, y the world's x, z from its place) is
-- the same prism on its side: its outline in x and z, its depth up and down; its
-- edges are upright walls (a step climbs one as a voxel's side, never as a slope),
-- an edge's info nx, ny its normal's x and z (info.flat), its top face W:down's. In a
-- level plane it is met where its depth spans the plane's y. A floor (kit/polygon's
-- `floor` on, `collision` off; lying flat only) is no wall: w:under(x, y, z) gives
-- its info over its area, the point no lower than its bottom and at most 0.6 over
-- its top (W:floor_at, before what is under it), and a walker's s.surface and
-- s.friction are its own.
-- simplified: one turned otherwise (neither standing nor flat, a pitch off 0 and
-- +-90) or on a moving object is not met, nor by W:ray; a circle's middle deeper in
-- one than its radius meets nothing of it
local M = {}
local floor, sqrt = math.floor, math.sqrt
local PI = 3.14159265358979323846
local EPS = 1e-4

local function abs(x)
	return x < 0 and -x or x
end

-- ---- Trigonometry of its own: Taylor series after the reduction, good
-- to 1e-14, the same bits on every side
-- The last ones kept: a movement asks the same few each step (the yaw's,
-- the slope limit's), and a series is dear in the box
local sin_cache, sin_n = {}, 0
function M.sin(x)
	local c = sin_cache[x]
	if c then
		return c
	end
	local x0 = x
	x = x - floor(x / (2 * PI) + 0.5) * 2 * PI
	if x > PI / 2 then
		x = PI - x
	elseif x < -PI / 2 then
		x = -PI - x
	end
	local x2, t, s = x * x, x, x
	for n = 1, 9 do
		t = -t * x2 / ((2 * n) * (2 * n + 1))
		s = s + t
	end
	if sin_n >= 64 then
		sin_cache, sin_n = {}, 0
	end
	sin_cache[x0], sin_n = s, sin_n + 1
	return s
end

function M.cos(x)
	return M.sin(x + PI / 2)
end

local function atan(t)
	local neg = t < 0
	if neg then
		t = -t
	end
	local inv = t > 1
	if inv then
		t = 1 / t
	end
	-- Halved twice: |t| <= tan(pi / 16)
	t = t / (1 + sqrt(1 + t * t))
	t = t / (1 + sqrt(1 + t * t))
	local t2, p, s = t * t, t, t
	for n = 1, 10 do
		p = -p * t2
		s = s + p / (2 * n + 1)
	end
	s = 4 * s
	if inv then
		s = PI / 2 - s
	end
	return neg and -s or s
end

function M.atan2(y, x)
	if x > 0 then
		return atan(y / x)
	elseif x < 0 then
		return atan(y / x) + (y >= 0 and PI or -PI)
	end
	return y > 0 and PI / 2 or y < 0 and -PI / 2 or 0
end
M.sqrt = sqrt
M.PI = PI

-- ---- [KIT_SMALL_PIECES] exp and pow of its own, as sin's: + - * / and floor,
-- the same bits on every side. The constants are integers over powers of two
-- (the box's number parsing is exact for those, not for long decimals).
-- exp good to 1e-15 relative; pow is exp(y log x), good to about 1e-13 relative
-- where y log x is large; a whole y up to 2^31 is multiplications.
-- simplified: no extended-precision log in pow (fdlibm's pow is the upgrade)
local LN2_HI = 2977044471 / 4294967296
local LN2_LO = 3691024475790907 / 4398046511104 / 4398046511104
local INV_LN2 = 1 / (LN2_HI + LN2_LO)
-- 2^(2^(i - 1)) and 2^(i - 1), i = 1...10
local TWO, BIT = {}, {}
do
	local v, b = 2, 1
	for i = 1, 10 do
		TWO[i], BIT[i], v, b = v, b, v * v, b * 2
	end
end
-- 2^k, a whole k within 1023 either way, exact
local function pow2(k)
	local r, n = 1, abs(k)
	for i = 1, 10 do
		if n % 2 == 1 then
			r = r * TWO[i]
		end
		n = floor(n / 2)
	end
	return k < 0 and 1 / r or r
end

function M.exp(x)
	if x ~= x then
		return x
	elseif x > 710 then
		return math.huge
	elseif x < -746 then
		return 0
	end
	local k = floor(x * INV_LN2 + 0.5)
	local r = (x - k * LN2_HI) - k * LN2_LO
	local s = 1
	for n = 17, 1, -1 do
		s = 1 + s * r / n
	end
	-- (in two halves: 2^k itself may be past a double either way)
	local h = floor(k / 2)
	return s * pow2(h) * pow2(k - h)
end

-- x > 0 and finite: x = m 2^e, m within 0.7...1.42, then the series of atanh
local function log(x)
	local e = 0
	if x >= 2 then
		for i = 10, 1, -1 do
			if x >= TWO[i] then
				x, e = x / TWO[i], e + BIT[i]
			end
		end
	elseif x < 1 then
		-- (twice: a subnormal is past 2^-1023)
		for _ = 1, 2 do
			for i = 10, 1, -1 do
				if x * TWO[i] < 2 then
					x, e = x * TWO[i], e - BIT[i]
				end
			end
		end
	end
	if x > 1.4142 then
		x, e = x / 2, e + 1
	end
	local f = (x - 1) / (x + 1)
	local s, t = f * f, 1 / 29
	for n = 13, 0, -1 do
		t = 1 / (2 * n + 1) + s * t
	end
	return 2 * f * t + e * LN2_LO + e * LN2_HI
end

-- C's pow on its edges: 1 for y 0 or x 1, NaN for a negative x and a fractional y
function M.pow(x, y)
	if y == 0 or x == 1 then
		return 1
	elseif x ~= x or y ~= y then
		return x + y
	end
	if y == floor(y) and abs(y) < 2147483648 then
		local n, r, b = abs(y), 1, x
		while n > 0 do
			if n % 2 == 1 then
				r = r * b
			end
			b, n = b * b, floor(n / 2)
		end
		return y < 0 and 1 / r or r
	end
	local ax = abs(x)
	if ax == math.huge then
		return y > 0 and ax or 0
	elseif x == 0 then
		return y < 0 and math.huge or 0
	elseif x < 0 then
		if y ~= floor(y) then
			return 0 / 0
		end
		-- (|y| past 2^31: odd or even; from 2^53 on a double is even)
		local r = M.exp(y * log(ax))
		return y % 2 == 1 and -r or r
	end
	return M.exp(y * log(x))
end

-- [KIT_PLANE] stage 4: a movement's `math` on both sides (its file is run with it:
-- controls.lua, box.c's define), the same bits there: what IEEE makes exact and
-- this file's sin, cos, atan, atan2, [KIT_SMALL_PIECES] exp and pow; no random,
-- nor log or tan.
-- simplified: x ^ y is each side's own pow (it may differ in the last bit):
-- math.pow(x, y), or x * x
M.math = {floor = floor, ceil = math.ceil, sqrt = sqrt, abs = abs,
	fmod = math.fmod, min = math.min, max = math.max, huge = math.huge, pi = PI,
	sin = M.sin, cos = M.cos, atan = atan, atan2 = M.atan2, exp = M.exp,
	pow = M.pow}

-- ---- [KIT_GUIDE_STATIONS] A gun's shot (kit/turret's; kit.cpp's projectiles
-- fly it): its arc's height over the muzzle at d metres out along the ground,
-- fired at v m/s up at a radians, falling at g. kit/bot aims by it (M.aim, the
-- box's c.aim), a player's impact marker draws by it (M.impact, controls.lua)
function M.arc(v, g, a, d)
	local c = M.cos(a)
	if c < 1e-6 then
		return nil
	end
	local t = d / (v * c)
	return v * M.sin(a) * t - 0.5 * g * t * t
end

-- The flattest elevation (radians, up positive) between lo and hi whose arc
-- is h over the muzzle d out; nil: out of its reach. A bisection on M.arc up to
-- the angle of the highest arc at d (tan = v^2 / (g d)), where it rises with a
function M.aim(v, g, d, h, lo, hi)
	if v <= 0 or d < 1e-6 then
		return nil
	end
	local top = g > 0 and M.atan2(v * v, g * d) or PI / 2 - 1e-3
	if top < hi then
		hi = top
	end
	if lo > hi or (M.arc(v, g, lo, d) or -1e9) > h or (M.arc(v, g, hi, d) or -1e9) < h then
		return nil
	end
	for _ = 1, 40 do
		local m = (lo + hi) / 2
		if M.arc(v, g, m, d) < h then
			lo = m
		else
			hi = m
		end
	end
	return (lo + hi) / 2
end

-- Where a shot from o ({x, y, z}) along the unit d at v m/s, falling at g,
-- first meets a solid cell (solid(i, j, k), a cell's middle its whole
-- coordinates) within life seconds: x, y, z, true; else its arc's end, false.
-- Steps of `step` m along the ground (kit.cpp's ray_wall takes 0.1 m).
-- [KIT_STATIONS_LEFTOVERS] seg(ax, ay, az, bx, by, bz), if given: what else
-- a step's chord meets first (entities, ships), its fraction 0...1 or nil
function M.impact(v, g, life, o, d, solid, step, seg)
	local h = sqrt(d[1] * d[1] + d[3] * d[3])
	if h < 1e-6 then
		return o[1], o[2], o[3], false
	end
	local a = M.atan2(d[2], h)
	local ux, uz = d[1] / h, d[3] / h
	local far = v * M.cos(a) * life
	step = step or 0.25
	local x, y, z = o[1], o[2], o[3]
	local s = 0
	while s < far do
		s = s + step < far and s + step or far
		local px, py, pz = x, y, z
		x, y, z = o[1] + ux * s, o[2] + M.arc(v, g, a, s), o[3] + uz * s
		local f = seg and seg(px, py, pz, x, y, z)
		if f then
			return px + (x - px) * f, py + (y - py) * f, pz + (z - pz) * f, true
		end
		if solid(floor(x + 0.5), floor(y + 0.5), floor(z + 0.5)) then
			return x, y, z, true
		end
	end
	return x, y, z, false
end

-- ---- Infos
M.UNKNOWN = {solid = true, friction = 1, surface = "unknown"}
M.OBJECT = {solid = true, friction = 1, surface = "object"}
M.GROUND = {solid = true, friction = 1, surface = "ground"}
M.EDGE = {solid = true, friction = 1, surface = "edge"}

-- A voxel's info from its definition's values (the server's table, both
-- sides): solid, friction (1 if none), surface ("" if none: its name's
-- after the author)
-- ([KIT_VOXEL_FORMAT]) and boxes: a shape's, {x0, y0, z0, x1, y1, z1, ...}
-- in the cell's -0.5...0.5 (none: the whole cell); the surface of a shape
-- ("kit/stone:stair") its material's
function M.voxel_info(name, solid, friction, surface, boxes)
	if not solid then
		return nil
	end
	if not surface or surface == "" then
		surface = tostring(name):match("([^/:]*)[^/]*$") or ""
	end
	local info = {solid = true, friction = tonumber(friction) or 1,
		surface = surface}
	if type(boxes) == "table" and #boxes >= 6 then
		info.boxes = boxes
	end
	return info
end

-- A cell's sub-boxes in the world (a shape's), or nil for the whole cell
local function cell_boxes(info, i, j, k)
	local bx = info.boxes
	if not bx then
		return nil
	end
	local out = {}
	for q = 1, #bx - 5, 6 do
		out[#out + 1] = {i + bx[q], j + bx[q + 1], k + bx[q + 2],
			i + bx[q + 3], j + bx[q + 4], k + bx[q + 5], info = info}
	end
	return out
end

-- ---- Looks as boxes: an object's look (module.lua's look_box: its size,
-- its middle off the entity, `when` over it while its state is on, a
-- swing a quarter turn round its -x edge) turned by its look's rotation
-- and the entity's turn (yaw, pitch, roll), as the box round it {x0, y0, z0,
-- x1, y1, z1}; nil when it is not solid
local function m3(a, b)
	local r = {}
	for i = 0, 2 do
		for j = 0, 2 do
			local s = 0
			for k = 0, 2 do
				s = s + a[i * 3 + k + 1] * b[k * 3 + j + 1]
			end
			r[i * 3 + j + 1] = s
		end
	end
	return r
end
local function rotation(rx, ry, rz)
	local function ry_(d)
		local c, s = M.cos(d * PI / 180), M.sin(d * PI / 180)
		return {c, 0, s, 0, 1, 0, -s, 0, c}
	end
	local function rx_(d)
		local c, s = M.cos(d * PI / 180), M.sin(d * PI / 180)
		return {1, 0, 0, 0, c, -s, 0, s, c}
	end
	local function rz_(d)
		local c, s = M.cos(d * PI / 180), M.sin(d * PI / 180)
		return {c, -s, 0, s, c, 0, 0, 0, 1}
	end
	return m3(ry_(ry), m3(rx_(rx), rz_(rz)))
end

-- [RACER_FEEL] (1) A turn's angles (yaw, pitch, roll; degrees, each 0...360 to a
-- millionth) from its quaternion, as kit.cpp's Turn::angles has them for the
-- server's steps: at a pitch of +-90 all of it yaw. The client's from its node's
-- float rotation (Urho3D's EulerAngles put it all in roll, and snapped pitches
-- past 84 to 90); the gimbal's threshold wide enough for a float's
local function round_to(a, k)
	return (a < 0 and -floor(-a * k + 0.5) or floor(a * k + 0.5)) / k
end
local function deg360(a)
	a = math.fmod(a, 360) + 0.0
	return a < 0 and a + 360 or a
end
function M.turn_angles(w, x, y, z)
	local d = 180 / PI
	local check = 2 * (w * x - y * z)
	local yaw, pitch, roll
	if abs(check) > 1 - 1e-6 then
		pitch, yaw, roll = check > 0 and 90 or -90, 2 * M.atan2(y, w) * d, 0
	else
		pitch = M.atan2(check, sqrt(1 - check * check)) * d
		yaw = M.atan2(2 * (x * z + w * y), 1 - 2 * (x * x + y * y)) * d
		roll = M.atan2(2 * (x * y + w * z), 1 - 2 * (x * x + z * z)) * d
	end
	return deg360(round_to(yaw, 1e6)), deg360(round_to(pitch, 1e6)),
			deg360(round_to(roll, 1e6))
end
-- A flat one's turn (pitch +-90, any yaw and roll) as one yaw, to a thousandth of
-- a degree, roll 0: the server's (all yaw) and a client's (from a float
-- quaternion) the same bits. Ry(y) Rx(90) Rz(r) is Ry(y - r) Rx(90); at -90 y + r
local function flat_turn(yaw, pitch, roll)
	local p = pitch > 180 and pitch - 360 or pitch
	if abs(abs(p) - 90) >= 1e-3 then
		return yaw, pitch, roll
	end
	local y = p > 0 and yaw - roll or yaw + roll
	return deg360(round_to(deg360(y), 1e3)), p > 0 and 90 or -90, 0
end
M.flat_turn = flat_turn

function M.look_box(look, on, pos, yaw, pitch, roll)
	-- ([KIT_MOVING_OBJECTS] or yaw the entity's turn as a matrix)
	-- ([KIT_PLANE] stage 3: a polygon is no box: M.look_poly)
	if type(look) ~= "table" or look.shape == "polygon" then
		return nil
	end
	local size, off = {}, {0, 0, 0}
	if type(look.size) == "table" then
		for i = 1, 3 do
			local v = tonumber(look.size[i]) or 1
			size[i] = v < 0.02 and 0.02 or v > 64 and 64 or v
		end
	else
		local v = (tonumber(look.size) or 0.4) * 2
		size = {v, v, v}
	end
	if type(look.offset) == "table" then
		for i = 1, 3 do
			off[i] = tonumber(look.offset[i]) or 0
		end
	end
	local w = on and type(look.when) == "table" and look.when or {}
	local solid = look.solid == true
	if w.solid ~= nil then
		solid = w.solid == true
	end
	if not solid then
		return nil
	end
	-- [KIT] stage 4l: moved by when.offset while on (kit/mover).
	-- simplified: where the state has it at once, not along its slide
	if type(w.offset) == "table" then
		for i = 1, 3 do
			off[i] = off[i] + (tonumber(w.offset[i]) or 0)
		end
	end
	if type(w.scale) == "table" then
		for i = 1, 3 do
			local was = size[i]
			size[i] = size[i] * (tonumber(w.scale[i]) or 1)
			if i == 2 then
				off[2] = off[2] - (was - size[2]) / 2
			end
		end
	end
	if w.swing then
		-- [KIT_DOOR_MIRROR] mirror: the other way, from its back to -z
		local hinge, front = off[1] - size[1] / 2, off[3] - size[3] / 2
		local back = off[3] + size[3] / 2
		size[1], size[3] = size[3], size[1]
		off[1] = hinge + size[1] / 2
		off[3] = w.mirror == true and back - size[3] / 2 or
				front + size[3] / 2
	end
	local r = type(look.rotation) == "table" and look.rotation or {}
	local R
	pitch, roll = tonumber(pitch) or 0, tonumber(roll) or 0
	if type(yaw) == "table" then
		R = m3(yaw, rotation(tonumber(r[1]) or 0, tonumber(r[2]) or 0, tonumber(r[3]) or 0))
	elseif pitch == 0 and roll == 0 then
		R = rotation(tonumber(r[1]) or 0, (tonumber(r[2]) or 0) +
				(tonumber(yaw) or 0), tonumber(r[3]) or 0)
	else
		R = m3(rotation(pitch, tonumber(yaw) or 0, roll), rotation(
				tonumber(r[1]) or 0, tonumber(r[2]) or 0, tonumber(r[3]) or 0))
	end
	-- simplified: the turned box's bounds, the box round it; a wedge is
	-- its whole box
	local b = {math.huge, math.huge, math.huge, -math.huge, -math.huge,
		-math.huge}
	for cx = -1, 1, 2 do for cy = -1, 1, 2 do for cz = -1, 1, 2 do
		local v = {off[1] + cx * size[1] / 2, off[2] + cy * size[2] / 2,
			off[3] + cz * size[3] / 2}
		for i = 0, 2 do
			local c = R[i * 3 + 1] * v[1] + R[i * 3 + 2] * v[2] +
					R[i * 3 + 3] * v[3] + pos[i + 1]
			if c < b[i + 1] then b[i + 1] = c end
			if c > b[i + 4] then b[i + 4] = c end
		end
	end end end
	return b
end

-- ---- [KIT_PLANE] stage 3: a polygon look as a prism (the top of this file says
-- what): {pts = {x1, y1, x2, y2...} in the world, the solid on the right going
-- round, n, z0, z1, x0, y0, x1, y1 its box, info, inf (its edges' infos)}; nil when
-- it is not met
M.POLYGON = {solid = true, friction = 1, surface = "polygon"}
-- [KIT_CLIENT_REACT] (5) a look's own surface and friction (none: M.POLYGON)
local function poly_info(look)
	local f, s = tonumber(look.friction), look.surface
	if type(s) ~= "string" or s == "" then
		s = "polygon"
	end
	if (f == nil or f == 1) and s == "polygon" then
		return M.POLYGON
	end
	f = f or 1
	return {solid = true, friction = f < 0 and 0 or f > 10 and 10 or f, surface = s}
end
-- [KIT_TOP_DOWN] (2) one lying flat (its own z along the world's y: pitch 90 or -90,
-- any yaw and roll): its pts the world's x and z, its depth along y (p.da 2, else 3),
-- met as a standing one is along those axes (W:sweep_polys); p.floor: a floor (not
-- solid, look.floor): no wall, what w:under meets over its area (W:floor_at)
function M.look_poly(look, on, pos, yaw, pitch, roll)
	if type(look) ~= "table" or look.shape ~= "polygon" or
			type(look.points) ~= "table" or type(yaw) == "table" then
		return nil
	end
	local w = on and type(look.when) == "table" and look.when or {}
	local solid = look.solid == true
	if w.solid ~= nil then
		solid = w.solid == true
	end
	local fl = not solid and look.floor == true
	-- ([RACER_FEEL] (1) a flat one's turn as one yaw, the same on both sides)
	pitch, yaw, roll = tonumber(pitch) or 0, tonumber(yaw) or 0, tonumber(roll) or 0
	yaw, pitch, roll = flat_turn(yaw, pitch, roll)
	local R = rotation(pitch, yaw, roll)
	local da = abs(R[9]) >= 1 - 1e-9 and 3 or abs(R[6]) >= 1 - 1e-9 and 2 or nil
	if not (solid or fl) or not da or fl and da ~= 2 then
		return nil
	end
	-- (the world's axis of its 2D y)
	local V = da == 3 and 2 or 3
	-- [KIT_CLIENT_REACT] (6) its `when` over it as over a box: scaled about its own
	-- point, then moved by its offset, in its own frame
	local sc, of = {1, 1, 1}, {0, 0, 0}
	for k = 1, 3 do
		sc[k] = type(w.scale) == "table" and tonumber(w.scale[k]) or 1
		of[k] = type(w.offset) == "table" and tonumber(w.offset[k]) or 0
	end
	local pts, n = {}, 0
	for _, p in ipairs(look.points) do
		local x = type(p) == "table" and tonumber(p[1])
		local y = type(p) == "table" and tonumber(p[2])
		if not x or not y then
			return nil
		end
		x, y = x * sc[1] + of[1], y * sc[2] + of[2]
		pts[2 * n + 1] = pos[1] + R[1] * x + R[2] * y
		pts[2 * n + 2] = pos[V] + R[3 * V - 2] * x + R[3 * V - 1] * y
		n = n + 1
	end
	if n < 3 then
		return nil
	end
	-- Twice its area, counter-clockwise positive: then turned round
	local a = 0
	for i = 1, n do
		local j = i % n + 1
		a = a + pts[2 * i - 1] * pts[2 * j] - pts[2 * j - 1] * pts[2 * i]
	end
	if a == 0 then
		return nil
	end
	if a > 0 then
		for i = 1, floor(n / 2) do
			local j = n + 1 - i
			pts[2 * i - 1], pts[2 * j - 1] = pts[2 * j - 1], pts[2 * i - 1]
			pts[2 * i], pts[2 * j] = pts[2 * j], pts[2 * i]
		end
	end
	local p = {pts = pts, n = n, info = poly_info(look), inf = {}, da = da,
		floor = fl or nil, x0 = math.huge, y0 = math.huge, x1 = -math.huge,
		y1 = -math.huge}
	for i = 1, n do
		local x, y = pts[2 * i - 1], pts[2 * i]
		if x < p.x0 then p.x0 = x end
		if x > p.x1 then p.x1 = x end
		if y < p.y0 then p.y0 = y end
		if y > p.y1 then p.y1 = y end
	end
	local d = tonumber(look.depth) or 1
	d = (d < 0.02 and 0.02 or d > 64 and 64 or d) * abs(sc[3])
	local zc = pos[da] + R[3 * da] * of[3]
	p.z0, p.z1 = zc - d / 2, zc + d / 2
	return p
end

-- A polygon's edge i's info (its normal out of it)
local function edge_info(p, i)
	local e = p.inf[i]
	if not e then
		local j = i % p.n + 1
		local ex, ey = p.pts[2 * j - 1] - p.pts[2 * i - 1], p.pts[2 * j] - p.pts[2 * i]
		local l = sqrt(ex * ex + ey * ey)
		-- ([KIT_TOP_DOWN] a flat one's: nx, ny the world's x and z, flat: an upright
		-- wall)
		e = {solid = true, friction = p.info.friction, surface = p.info.surface,
			nx = l > 0 and -ey / l or 0, ny = l > 0 and ex / l or 0,
			flat = p.da == 2 or nil}
		p.inf[i] = e
	end
	return e
end

-- Whether x, y is inside it (even-odd)
local function poly_inside(p, x, y)
	local q, n, inside = p.pts, p.n, false
	for i = 1, n do
		local j = i % n + 1
		local ay, by = q[2 * i], q[2 * j]
		if (ay > y) ~= (by > y) and x < q[2 * i - 1] + (y - ay) *
				(q[2 * j - 1] - q[2 * i - 1]) / (by - ay) then
			inside = not inside
		end
	end
	return inside
end

-- Whether the rectangle (a hair in from its sides) and its area overlap: an edge
-- through it, or its middle inside
local function poly_over(p, x0, y0, x1, y1)
	x0, y0, x1, y1 = x0 + EPS, y0 + EPS, x1 - EPS, y1 - EPS
	if p.x1 <= x0 or p.x0 >= x1 or p.y1 <= y0 or p.y0 >= y1 then
		return false
	end
	local q, n = p.pts, p.n
	for i = 1, n do
		local j = i % n + 1
		local ax, ay = q[2 * i - 1], q[2 * i]
		local dx, dy = q[2 * j - 1] - ax, q[2 * j] - ay
		-- (Liang and Barsky)
		local t0, t1 = 0, 1
		for k = 1, 4 do
			local pp = k == 1 and -dx or k == 2 and dx or k == 3 and -dy or dy
			local qq = k == 1 and ax - x0 or k == 2 and x1 - ax or k == 3 and ay - y0 or
					y1 - ay
			if pp == 0 then
				if qq < 0 then
					t0 = 2
				end
			else
				local r = qq / pp
				if pp < 0 then
					if r > t0 then t0 = r end
				elseif r < t1 then
					t1 = r
				end
			end
		end
		if t0 <= t1 then
			return true
		end
	end
	return poly_inside(p, (x0 + x1) / 2, (y0 + y1) / 2)
end

-- A simple polygon's triangles (ear clipping; the client's mesh): {i, j, k, ...}
-- indices of its points ({x1, y1, x2, y2...}), each counter-clockwise
function M.triangulate(pts)
	local n = floor(#pts / 2)
	local a = 0
	for i = 1, n do
		local j = i % n + 1
		a = a + pts[2 * i - 1] * pts[2 * j] - pts[2 * j - 1] * pts[2 * i]
	end
	local idx, out = {}, {}
	for i = 1, n do
		idx[i] = a >= 0 and i or n + 1 - i
	end
	local function cross(i, j, k)
		return (pts[2 * j - 1] - pts[2 * i - 1]) * (pts[2 * k] - pts[2 * i]) -
				(pts[2 * j] - pts[2 * i]) * (pts[2 * k - 1] - pts[2 * i - 1])
	end
	while #idx > 3 do
		local m, cut = #idx, nil
		for c = 1, m do
			local i, j, k = idx[(c - 2) % m + 1], idx[c], idx[c % m + 1]
			if cross(i, j, k) > 0 then
				local ear = true
				for _, q in ipairs(idx) do
					if q ~= i and q ~= j and q ~= k and cross(i, j, q) >= 0 and
							cross(j, k, q) >= 0 and cross(k, i, q) >= 0 then
						ear = false
						break
					end
				end
				if ear then
					out[#out + 1], out[#out + 2], out[#out + 3] = i, j, k
					cut = c
					break
				end
			end
		end
		-- None: a point on a line is dropped; else it is no simple polygon
		for c = 1, cut and 0 or m do
			if cross(idx[(c - 2) % m + 1], idx[c], idx[c % m + 1]) == 0 then
				cut = c
				break
			end
		end
		if not cut then
			return out
		end
		for c = cut, m - 1 do
			idx[c] = idx[c + 1]
		end
		idx[m] = nil
	end
	if #idx == 3 and cross(idx[1], idx[2], idx[3]) > 0 then
		out[#out + 1], out[#out + 2], out[#out + 3] = idx[1], idx[2], idx[3]
	end
	return out
end

-- [KIT_MOVING_OBJECTS] What the object's motion is at t (seconds): the turn over its
-- own (pitch, yaw, roll, degrees), how far up its own axis, how far along its course
-- (0...1...0)
local function swing(amp, period, t)
	amp, period = tonumber(amp) or 0, tonumber(period) or 0
	if amp == 0 or period <= 0 then
		return 0
	end
	return amp * M.sin(2 * PI * t / period)
end
function M.wave(m, t)
	local ct, u = tonumber(m.course_time) or 0, 0
	if ct > 0 then
		u = t / ct
		u = u - 2 * floor(u / 2)
		u = u > 1 and 2 - u or u
	end
	return swing(m.wave_pitch, m.wave_pitch_period, t),
			swing(m.wave_yaw, m.wave_yaw_period, t),
			swing(m.wave_roll, m.wave_roll_period, t),
			swing(m.wave_heave, m.wave_heave_period, t), u
end

local function vec3(v)
	if type(v) ~= "table" then
		return 0, 0, 0
	end
	return tonumber(v[1]) or 0, tonumber(v[2]) or 0, tonumber(v[3]) or 0
end

-- [KIT_VEHICLE_MOVEMENTS] A steered object's track: M.tracks[entity] its keys, each
-- {t ms, x, y, z, yaw, pitch, roll} (its place and turn in its parent's frame), in
-- order; the client's from "kit:track", the box's each request's (M.snapshot). At t
-- (seconds): between the two round it, past the last on from the two last for half
-- a second at most, before the first the first (kit.cpp's track_at says the same).
-- nil: no keys
M.tracks = {}
function M.track_at(id, t)
	local k = M.tracks[id]
	if type(k) ~= "table" or #k == 0 then
		return nil
	end
	local ms = t * 1000
	if ms <= k[1][1] then
		local a = k[1]
		return a[2], a[3], a[4], a[5], a[6], a[7]
	end
	local lo, hi = 1, #k
	while lo < hi do
		local mid = floor((lo + hi + 1) / 2)
		if k[mid][1] <= ms then
			lo = mid
		else
			hi = mid - 1
		end
	end
	local a, b, u = k[lo], k[lo + 1], 0
	if b then
		u = (ms - a[1]) / (b[1] - a[1])
	elseif lo > 1 then
		a, b = k[lo - 1], k[lo]
		u = ((ms < b[1] + 500 and ms or b[1] + 500) - a[1]) / (b[1] - a[1])
	else
		return a[2], a[3], a[4], a[5], a[6], a[7]
	end
	local r = {}
	for i = 2, 7 do
		local d = b[i] - a[i]
		if i >= 5 then
			d = d - 360 * floor((d + 180) / 360)
		end
		r[i] = a[i] + d * u
	end
	return r[2], r[3], r[4], r[5], r[6], r[7]
end

-- A link {x, y, z, yaw, pitch, roll, motion} (an object at rest in the world, what
-- moves it) at t: where its origin is, D, the world's turn it makes round where its
-- origin was at rest, and the wave's angles (kit.cpp's moved_local says the same in
-- the object's parent). [KIT_VEHICLE_MOVEMENTS] A steered one's (motion.track its
-- entity, motion.frame its parent's frame at rest {x, y, z, yaw, pitch, roll}): its
-- track's place and turn there, the wave on top; then also the track's yaw, pitch
-- and roll
function M.link_at(l, t)
	local R0 = l.R0
	if not R0 then
		R0 = rotation(tonumber(l[5]) or 0, tonumber(l[4]) or 0, tonumber(l[6]) or 0)
		l.R0 = R0
	end
	local m = l[7]
	local wp, wy, wr, h, u = M.wave(m, t)
	local W = rotation(wp, wy, wr)
	local px, py, pz = vec3(m.pivot)
	local cx, cy, cz = vec3(m.course)
	local vx = px + cx * u - (W[1] * px + W[2] * py + W[3] * pz)
	local vy = py + cy * u + h - (W[4] * px + W[5] * py + W[6] * pz)
	local vz = pz + cz * u - (W[7] * px + W[8] * py + W[9] * pz)
	local kx, ky, kz, kyaw, kpitch, kroll
	if m.track and type(m.frame) == "table" then
		kx, ky, kz, kyaw, kpitch, kroll = M.track_at(m.track, t)
	end
	if kx then
		local f = m.frame
		local F = l.F
		if not F then
			F = rotation(tonumber(f[5]) or 0, tonumber(f[4]) or 0, tonumber(f[6]) or 0)
			l.F = F
		end
		local FK = m3(F, rotation(kpitch, kyaw, kroll))
		local A = m3(FK, W)
		local D = {}
		for i = 0, 2 do
			for j = 0, 2 do
				D[i * 3 + j + 1] = A[i * 3 + 1] * R0[j * 3 + 1] + A[i * 3 + 2] * R0[j * 3 + 2]
						+ A[i * 3 + 3] * R0[j * 3 + 3]
			end
		end
		local fx, fy, fz = vec3(f)
		return fx + F[1] * kx + F[2] * ky + F[3] * kz + FK[1] * vx + FK[2] * vy + FK[3] * vz,
				fy + F[4] * kx + F[5] * ky + F[6] * kz + FK[4] * vx + FK[5] * vy + FK[6] * vz,
				fz + F[7] * kx + F[8] * ky + F[9] * kz + FK[7] * vx + FK[8] * vy + FK[9] * vz,
				D, wp, wy, wr, kyaw, kpitch, kroll
	end
	local A = m3(R0, W)
	local D = {}
	for i = 0, 2 do
		for j = 0, 2 do
			D[i * 3 + j + 1] = A[i * 3 + 1] * R0[j * 3 + 1] + A[i * 3 + 2] * R0[j * 3 + 2]
					+ A[i * 3 + 3] * R0[j * 3 + 3]
		end
	end
	return l[1] + R0[1] * vx + R0[2] * vy + R0[3] * vz,
			l[2] + R0[4] * vx + R0[5] * vy + R0[6] * vz,
			l[3] + R0[7] * vx + R0[8] * vy + R0[9] * vz, D, wp, wy, wr
end

-- A place and turn at rest as its links have them at t (the nearest link first)
local function pose_of(links, x, y, z, R, t)
	for _, l in ipairs(links) do
		local xt, yt, zt, D = M.link_at(l, t)
		local dx, dy, dz = x - l[1], y - l[2], z - l[3]
		x = xt + D[1] * dx + D[2] * dy + D[3] * dz
		y = yt + D[4] * dx + D[5] * dy + D[6] * dz
		z = zt + D[7] * dx + D[8] * dy + D[9] * dz
		R = m3(D, R)
	end
	return x, y, z, R
end

-- A point or direction into an object's frame, and out of it (R: frame to world)
local function into(o, x, y, z)
	local R = o.R
	return R[1] * x + R[4] * y + R[7] * z, R[2] * x + R[5] * y + R[8] * z,
			R[3] * x + R[6] * y + R[9] * z
end
local function outof(o, x, y, z)
	local R = o.R
	return R[1] * x + R[2] * y + R[3] * z, R[4] * x + R[5] * y + R[6] * z,
			R[7] * x + R[8] * y + R[9] * z
end

-- [KIT_FREE_PREFAB] The free voxel objects as a world's t.turned: from {x, y, z,
-- yaw, pitch, roll, {x0, y0, z0, x1, y1, z1, ...}, id} (a place, a turn, boxes in
-- that frame, its entity). [KIT_WALKER_FRAME] A body outside its frame meets one
-- as a box of the object's axes, from its feet: turned with the object. A body
-- standing on it steps in its frame. [KIT_MOVING_OBJECTS] And o[9], its links
-- (M.link_at): W:pose_at moves it.
function M.turned(list)
	local out = {}
	for _, o in ipairs(list) do
		local b, rad, boxes = o[7], 0, {}
		for i = 1, #b - 5, 6 do
			boxes[#boxes + 1] = {b[i], b[i + 1], b[i + 2], b[i + 3], b[i + 4],
				b[i + 5]}
			local e = {b[i], b[i + 1], b[i + 2]}
			for k = 1, 3 do
				if abs(b[i + k + 2]) > abs(e[k]) then
					e[k] = b[i + k + 2]
				end
			end
			local d = sqrt(e[1] * e[1] + e[2] * e[2] + e[3] * e[3])
			rad = d > rad and d or rad
		end
		local t = {id = o[8], x = o[1], y = o[2], z = o[3], rad = rad, b = boxes,
			R = rotation(tonumber(o[5]) or 0, tonumber(o[4]) or 0, tonumber(o[6]) or 0)}
		if type(o[9]) == "table" and #o[9] > 0 then
			t.links, t.x0, t.y0, t.z0, t.R0 = o[9], t.x, t.y, t.z, t.R
		end
		-- What a sweep along y meets on its top: M.OBJECT and the way in
		t.info = {solid = true, friction = 1, surface = "object", frame = t}
		out[#out + 1] = t
	end
	return out
end

-- ---- The world: t.cell(i, j, k) -> info or nil, t.boxes ({x0, y0, z0,
-- x1, y1, z1, info = ...}...), t.turned (M.turned), t.ground(x, z) -> a
-- heightmap's height
-- or nil, t.edge {x0, z0, x1, z1}: a heightmap's extent. [KIT_HM_FREE]
-- Over a heightmap (t.ground or t.edge) a cell not loaded is air: its
-- voxels are only what is built, and a body walks on while they come in;
-- the extent is a wall: nobody walks off the map
local W = {}
W.sin, W.cos, W.atan2, W.sqrt, W.PI = M.sin, M.cos, M.atan2, sqrt, PI

function M.world(t)
	-- Copied in (the client's sandbox has no setmetatable)
	local w = {}
	for k, v in pairs(W) do
		w[k] = v
	end
	w.cell_fn = t.cell
	w.boxes = t.boxes or {}
	w.turned = t.turned or {}
	w.ground_fn = t.ground
	w.edge = t.edge
	w.unknown_air = t.ground ~= nil or t.edge ~= nil
	w.cache = {}
	-- [KIT_PLANE] the plane's z (nil: none); stage 3: the polygons' prisms
	w.plane = type(t.plane) == "number" and t.plane or nil
	-- [KIT_TOP_DOWN] (1) the plane level: w.plane a y
	w.horizontal = w.plane ~= nil and t.horizontal == true or nil
	-- ([KIT_TOP_DOWN] (2) the floors apart: no walls)
	w.polys, w.floors = {}, {}
	for _, p in ipairs(t.polys or {}) do
		local l = p.floor and w.floors or w.polys
		l[#l + 1] = p
	end
	-- [KIT_TOP_DOWN] (8) the other bodies a movement.bodies meets, {x, z, r, vx, vz,
	-- by} each, their info made once; in a level plane only
	w.bodies = {}
	for _, b in ipairs(w.horizontal and type(t.bodies) == "table" and t.bodies or {}) do
		local x, z, r = tonumber(b[1]), tonumber(b[2]), tonumber(b[3])
		if x and z and r then
			w.bodies[#w.bodies + 1] = {x, z, r, info = {solid = true, friction = 1,
				surface = "body", body = tostring(b[6]), vel = {tonumber(b[4]) or 0,
				tonumber(b[5]) or 0}}}
		end
	end
	-- [KIT_MOVING_OBJECTS] t.moving_looks: solid looks on moving objects, each
	-- {look, on, {x, y, z}, yaw, pitch, roll, links} at rest
	w.moving_looks = t.moving_looks
	w.moving = t.moving_looks ~= nil and #t.moving_looks > 0
	for _, o in ipairs(w.turned) do
		w.moving = w.moving or o.links ~= nil
	end
	if w.moving and t.t then
		w:pose_at(t.t)
	end
	return w
end

-- [KIT_MOVING_OBJECTS] The moving objects and looks of this world where they are at
-- t (seconds): both sides, for a step stamped t
function W:pose_at(t)
	self.t = t
	for _, o in ipairs(self.turned) do
		if o.links then
			o.x, o.y, o.z, o.R = pose_of(o.links, o.x0, o.y0, o.z0, o.R0, t)
		end
	end
	if self.moving_looks then
		if not self.static_boxes then
			self.static_boxes = self.boxes
		end
		local b = {}
		for _, o in ipairs(self.static_boxes) do
			b[#b + 1] = o
		end
		for _, l in ipairs(self.moving_looks) do
			local p = l[3]
			local x, y, z, R = pose_of(l[7], p[1], p[2], p[3], rotation(tonumber(l[5]) or 0,
					tonumber(l[4]) or 0, tonumber(l[6]) or 0), t)
			local box = M.look_box(l[1], l[2], {x, y, z}, R)
			if box then
				box.links = l[7]
				b[#b + 1] = box
			end
		end
		self.boxes = b
	end
end

-- What a moving object's point goes at, in the world, as it is at self.t: m/s
function W:deck_velocity(o, x, y, z)
	if not o.links or not self.t then
		return 0, 0, 0
	end
	local lx, ly, lz = into(o, x - o.x, y - o.y, z - o.z)
	local dt = 0.02
	local ax, ay, az, R = pose_of(o.links, o.x0, o.y0, o.z0, o.R0, self.t - dt)
	local bx, by, bz = outof({R = R}, lx, ly, lz)
	return (x - bx - ax) / dt, (y - by - ay) / dt, (z - bz - az) / dt
end

function W:cell(i, j, k)
	-- A number (a string's making is dear in the box)
	local key = (i + 32768) + 65536 * ((j + 32768) + 65536 * (k + 32768))
	local v = self.cache[key]
	if v == nil then
		v = self.cell_fn(i, j, k) or false
		if v == M.UNKNOWN and self.unknown_air then
			v = false
		end
		self.cache[key] = v
	end
	return v or nil
end

-- The heightmap's height at x, z (nil: none there)
function W:height(x, z)
	return self.ground_fn and self.ground_fn(x, z) or nil
end

-- The highest ground under a footprint: its corners and middle
function W:ground_max(x0, z0, x1, z1)
	if not self.ground_fn then
		return nil
	end
	local best = nil
	for _, p in ipairs({{x0, z0}, {x1, z0}, {x0, z1}, {x1, z1},
			{(x0 + x1) / 2, (z0 + z1) / 2}}) do
		local h = self.ground_fn(p[1], p[2])
		if h and (not best or h > best) then
			best = h
		end
	end
	return best
end

local ray_turned

local function lo_cell(a)
	return floor(a + EPS - 0.5) + 1
end
local function hi_cell(a)
	return -floor(-(a - EPS + 0.5)) - 1
end

-- [KIT_WALKER_FRAME] The feet in an object's box grown by the body, a hair in from
-- the faces, so that one touching can go along or away: lo and hi
local function grown(f, r, h)
	return f[1] - r + EPS, f[2] - h + EPS, f[3] - r + EPS,
			f[4] + r - EPS, f[5] - EPS, f[6] + r - EPS
end

-- The sweep's move d along world axis a past the free objects: the body from its
-- feet along each object's axes, the move turned in. Along x and z any face stops
-- it. Along y what can hold a body does: an object's top, a face within 60 degrees
-- of level; a steeper side lets it past and W:shed moves it out, so that nothing
-- hangs on a leaning wall. On a top the info is the object's own (W:walk's way in).
function W:sweep_turned(b, a, d)
	local hit = nil
	local r, h = (b[4] - b[1]) / 2, b[5] - b[2]
	local fx, fy, fz = (b[1] + b[4]) / 2, b[2], (b[3] + b[6]) / 2
	for _, o in ipairs(self.turned) do
		local lx, ly, lz = into(o, fx - o.x, fy - o.y, fz - o.z)
		local reach = o.rad + 2 * r + h + abs(d)
		if o ~= self.skip and lx * lx + ly * ly + lz * lz <= reach * reach then
			local p = {lx, ly, lz}
			local m = {into(o, a == 1 and d or 0, a == 2 and d or 0,
					a == 3 and d or 0)}
			local t, len = 1, abs(d)
			for _, f in ipairs(len > 1e-12 and o.b or {}) do
				local x0, y0, z0, x1, y1, z1 = grown(f, r, h)
				local lo, hi = {x0, y0, z0}, {x1, y1, z1}
				-- One the body is in already is no wall: it gets out
				if not (lx > x0 and lx < x1 and ly > y0 and ly < y1 and
						lz > z0 and lz < z1) then
					local t0, t1, na = 0, 1, nil
					for q = 1, 3 do
						if abs(m[q]) < 1e-12 then
							if p[q] <= lo[q] or p[q] >= hi[q] then
								t0 = 2
							end
						else
							local e0, e1 = (lo[q] - p[q]) / m[q], (hi[q] - p[q]) / m[q]
							if e0 > e1 then
								e0, e1 = e1, e0
							end
							if e0 >= t0 then
								t0, na = e0, q
							end
							if e1 < t1 then
								t1 = e1
							end
						end
					end
					if na and t0 <= t1 and t0 < t then
						local top = a == 2 and d < 0 and na == 2 and m[2] < 0
						if a ~= 2 or top or abs(m[na]) >= 0.5 * len then
							-- Short of it by as much again
							t = t0 - 2 * EPS / len
							if t < 0 then
								t = 0
							end
							hit = top and o.info or M.OBJECT
						end
					end
				end
			end
			d = d * t
		end
	end
	return d, hit
end

-- A side passed by the sweep along y, moved: the feet out of it by its nearest
-- side, no more than the move's own size: x, y, z to add. Level objects have no
-- such side
function W:shed(x, y, z, r, h, moved)
	local sx, sy, sz = 0, 0, 0
	for _, o in ipairs(self.turned) do
		local lx, ly, lz = into(o, x - o.x, y - o.y, z - o.z)
		local reach = o.rad + 2 * r + h
		if abs(1 - o.R[5]) > 1e-9 and lx * lx + ly * ly + lz * lz <= reach * reach then
			for _, f in ipairs(o.b) do
				local x0, y0, z0, x1, y1, z1 = grown(f, r, h)
				if lx > x0 and lx < x1 and ly > y0 and ly < y1 and lz > z0 and lz < z1 then
					local best, ax, q = lx - x0, 1, -1
					if x1 - lx < best then best, ax, q = x1 - lx, 1, 1 end
					if lz - z0 < best then best, ax, q = lz - z0, 3, -1 end
					if z1 - lz < best then best, ax, q = z1 - lz, 3, 1 end
					if best <= abs(moved) + 2 * EPS then
						local e = q * (best + 2 * EPS)
						local dx, dy, dz = outof(o, ax == 1 and e or 0, 0,
								ax == 3 and e or 0)
						sx, sy, sz = sx + dx, sy + dy, sz + dz
						lx, ly, lz = into(o, x + sx - o.x, y + sy - o.y, z + sz - o.z)
					end
				end
			end
		end
	end
	return sx, sy, sz
end

-- [KIT_PLANE] stage 3: whether a polygon's prism is met by the box: in the plane
-- spanning its z, else the box's z within it
-- ([KIT_TOP_DOWN] (2) along its depth's axis: a flat one's y, met in a level plane
-- where it spans the plane's y)
local function spans(w, p, b)
	local da = p.da or 3
	if w.plane and (w.horizontal and 2 or 3) == da then
		return p.z0 < w.plane and p.z1 > w.plane
	end
	return p.z0 < b[da + 3] - EPS and p.z1 > b[da] + EPS
end

-- [KIT_TOP_DOWN] (2) The box b in a polygon's frame: its 2D x and y, its depth
local function poly_box(p, b)
	local da = p.da or 3
	local V = da == 3 and 2 or 3
	return {b[1], b[V], b[da], b[4], b[V + 3], b[da + 3]}
end

-- The move d cut to dist ahead (s its sign) when that is nearer: d, true
local function nearer(dist, d, s)
	if dist > -EPS and dist < s * d then
		return s * (dist < 0 and 0 or dist), true
	end
	return d, false
end

-- The box's move d along a past the polygons' prisms: d, the info hit
-- ([KIT_TOP_DOWN] (2) each in its own frame, poly_box's: a flat one's 2D y the
-- world's z, its faces along y)
function W:sweep_polys(b0, a0, d)
	local hit, s = nil, d > 0 and 1 or -1
	for _, p in ipairs(self.polys) do
		local b = poly_box(p, b0)
		if a0 == (p.da or 3) then
			-- Its faces: the box over the polygon's area
			local dist = s > 0 and p.z0 - b[6] or b[3] - p.z1
			if dist > -EPS and dist < s * d and poly_over(p, b[1], b[2], b[4], b[5]) then
				d, hit = s * (dist < 0 and 0 or dist), p.info
			end
		else
			local a = a0 == 1 and 1 or 2
			local v = 3 - a
			local lead = s > 0 and b[a + 3] or b[a]
			local v0, v1 = b[v] + EPS, b[v + 3] - EPS
			local lo = a == 1 and p.x0 or p.y0
			local hi = a == 1 and p.x1 or p.y1
			local plo = v == 1 and p.x0 or p.y0
			local phi = v == 1 and p.x1 or p.y1
			if spans(self, p, b0) and plo <= v1 and phi >= v0 and
					(s > 0 and hi >= lead - EPS and lo <= lead + d or
					s < 0 and lo <= lead + EPS and hi >= lead + d) then
				local q, n = p.pts, p.n
				for i = 1, n do
					local j = i % n + 1
					local pu, pv = q[2 * i - 2 + a], q[2 * i - 2 + v]
					local qu, qv = q[2 * j - 2 + a], q[2 * j - 2 + v]
					local eu, ev = qu - pu, qv - pv
					-- Its normal out ((-ey, ex)) against the move: coming at it
					if s * (a == 1 and -ev or ev) < 0 then
						local was = d
						-- The body's leading corners along the move onto it
						if (v0 - pv) * (v0 - qv) <= 0 then
							d = nearer((pu + (v0 - pv) * eu / ev - lead) * s, d, s)
						end
						if (v1 - pv) * (v1 - qv) <= 0 then
							d = nearer((pu + (v1 - pv) * eu / ev - lead) * s, d, s)
						end
						-- Its ends onto the body's leading face
						if pv > v0 and pv < v1 then
							d = nearer((pu - lead) * s, d, s)
						end
						if qv > v0 and qv < v1 then
							d = nearer((qu - lead) * s, d, s)
						end
						if d ~= was then
							hit = edge_info(p, i)
						end
					end
				end
			end
		end
	end
	return d, hit
end

-- The box b0..b1 ({x0, y0, z0, x1, y1, z1}) moved by d along axis a (1:
-- x, 2: y, 3: z) as far as the solid cells and boxes let it: the move,
-- and the info hit (nil: none)
function W:sweep(b, a, d)
	if d == 0 then
		return 0, nil
	end
	local lo, hi = {b[1], b[2], b[3]}, {b[4], b[5], b[6]}
	if d > 0 then
		hi[a] = hi[a] + d
	else
		lo[a] = lo[a] + d
	end
	local hit = nil
	-- Along a only the cells past the face (those it is in are no wall)
	local r0, r1 = {lo_cell(lo[1]), lo_cell(lo[2]), lo_cell(lo[3])},
		{hi_cell(hi[1]), hi_cell(hi[2]), hi_cell(hi[3])}
	if d > 0 then
		r0[a] = -floor(-(b[a + 3] - EPS + 0.5))
	else
		r1[a] = floor(b[a] + EPS - 0.5)
	end
	-- [KIT_SLAB_WALK] A shape's boxes in the cell the face is in are in
	-- the way too (a slab's top is mid-cell: a body standing on it has
	-- its feet in that cell); the boxes behind the face are left out below
	local e0, e1 = r0[a], r1[a]
	if d > 0 then
		e0 = e0 - 1
	else
		e1 = e1 + 1
	end
	local lo_a, hi_a = r0[a], r1[a]
	r0[a], r1[a] = e0, e1
	-- The shapes' boxes in the way, met with the objects' below
	local sub = nil
	for i = r0[1], r1[1] do
		for j = r0[2], r1[2] do
			for k = r0[3], r1[3] do
				local info = self:cell(i, j, k)
				local c = a == 1 and i or a == 2 and j or k
				if info and not info.boxes and (c < lo_a or c > hi_a) then
					info = nil
				end
				if info and info.boxes then
					sub = sub or {}
					for _, o in ipairs(cell_boxes(info, i, j, k)) do
						sub[#sub + 1] = o
					end
				elseif info then
					-- One the box is in already is no wall: it gets out
					if d > 0 then
						local lim = c - 0.5 - b[a + 3]
						if lim > -EPS and lim < d then
							d, hit = lim < 0 and 0 or lim, info
						end
					else
						local lim = c + 0.5 - b[a]
						if lim < EPS and lim > d then
							d, hit = lim > 0 and 0 or lim, info
						end
					end
				end
			end
		end
	end
	local function box_list(n)
		if n == 1 then return self.boxes end
		return sub or {}
	end
	for n = 1, 2 do for _, o in ipairs(box_list(n)) do
		local over = true
		for q = 1, 3 do
			if q ~= a and (o[q] >= b[q + 3] - EPS or o[q + 3] <= b[q] + EPS) then
				over = false
			end
		end
		if over then
			if d > 0 and o[a] >= b[a + 3] - EPS then
				local lim = o[a] - b[a + 3]
				if lim < d then
					d, hit = lim < 0 and 0 or lim, o.info or M.OBJECT
				end
			elseif d < 0 and o[a + 3] <= b[a] + EPS then
				local lim = o[a + 3] - b[a]
				if lim > d then
					d, hit = lim > 0 and 0 or lim, o.info or M.OBJECT
				end
			end
		end
	end end
	if self.polys[1] then
		local dp, hp = self:sweep_polys(b, a, d)
		d, hit = dp, hp or hit
	end
	local dt, ht = self:sweep_turned(b, a, d)
	d, hit = dt, ht or hit
	-- [KIT_HM_FREE] The heightmap's extent: a wall (one past it already:
	-- no further out)
	local e = self.edge
	if e and a ~= 2 then
		local q = a == 1 and 0 or 1
		if d > 0 then
			local lim = e[q + 3] - b[a + 3]
			if lim < d then
				d, hit = lim < 0 and 0 or lim, M.EDGE
			end
		else
			local lim = e[q + 1] - b[a]
			if lim > d then
				d, hit = lim > 0 and 0 or lim, M.EDGE
			end
		end
	end
	-- The heightmap stops a fall (one in it already: at once)
	if a == 2 and d < 0 then
		local g = self:ground_max(b[1], b[3], b[4], b[6])
		if g and g - b[2] > d then
			d, hit = g - b[2] > 0 and 0 or g - b[2], M.GROUND
		end
	end
	return d, hit
end

local function box_of(x, y, z, r, h)
	return {x - r, y, z - r, x + r, y + h, z + r}
end

-- [KIT_VEHICLE_MOVEMENTS] A moving look on the skipped object (a seat on the deck the
-- body stands on): its frame has it; as an axis-aligned box in the world, a turned deck's
-- look reaches past its sides
local function on_skipped(w, box)
	local d = w.skip and w.skip.links and w.skip.links[1]
	if not d or not box.links then
		return false
	end
	for _, l in ipairs(box.links) do
		if l[1] == d[1] and l[2] == d[2] and l[3] == d[3] then
			return true
		end
	end
	return false
end

-- Whether the box is in anything solid (known_only: not counting a cell not loaded;
-- self.skip left out)
function W:blocked(b, known_only)
	for i = lo_cell(b[1]), hi_cell(b[4]) do
		for j = lo_cell(b[2]), hi_cell(b[5]) do
			for k = lo_cell(b[3]), hi_cell(b[6]) do
				local info = self:cell(i, j, k)
				if info and info.boxes then
					for _, o in ipairs(cell_boxes(info, i, j, k)) do
						if o[1] < b[4] - EPS and o[4] > b[1] + EPS and
								o[2] < b[5] - EPS and o[5] > b[2] + EPS and
								o[3] < b[6] - EPS and o[6] > b[3] + EPS then
							return true
						end
					end
				elseif info and not (known_only and info == M.UNKNOWN) then
					return true
				end
			end
		end
	end
	for _, o in ipairs(self.boxes) do
		if o[1] < b[4] - EPS and o[4] > b[1] + EPS and o[2] < b[5] - EPS and
				o[5] > b[2] + EPS and o[3] < b[6] - EPS and o[6] > b[3] + EPS and
				not on_skipped(self, o) then
			return true
		end
	end
	for _, p in ipairs(self.polys) do
		local lb = poly_box(p, b)
		if spans(self, p, b) and poly_over(p, lb[1], lb[2], lb[4], lb[5]) then
			return true
		end
	end
	local r, h = (b[4] - b[1]) / 2, b[5] - b[2]
	for _, o in ipairs(self.turned) do
		local lx, ly, lz = into(o, (b[1] + b[4]) / 2 - o.x, b[2] - o.y,
				(b[3] + b[6]) / 2 - o.z)
		for _, f in ipairs(o ~= self.skip and o.b or {}) do
			local x0, y0, z0, x1, y1, z1 = grown(f, r, h)
			if lx > x0 and lx < x1 and ly > y0 and ly < y1 and lz > z0 and lz < z1 then
				return true
			end
		end
	end
	return false
end

-- [KIT_MOVING_OBJECTS] A moving object has come over a body not on it (its pose
-- changes between steps, and a sweep starts from one it is in as no wall): the feet
-- out by its nearest side, a top's up, as far as a step's change can be and not into
-- the world's; a body on its top is so caught as it lands.
-- simplified: PUSH_MOST a step, so an object faster than 30 m/s at its surface goes
-- past. A sweep from the last pose is the upgrade
local PUSH_MOST = 0.5
function W:pushed(pos, b)
	for _, o in ipairs(self.turned) do
		local lx, ly, lz = into(o, pos[1] - o.x, pos[2] - o.y, pos[3] - o.z)
		local reach = o.rad + 2 * b.r + b.h
		if o.links and lx * lx + ly * ly + lz * lz <= reach * reach then
			for _, f in ipairs(o.b) do
				local x0, y0, z0, x1, y1, z1 = grown(f, b.r, b.h)
				if lx > x0 and lx < x1 and ly > y0 and ly < y1 and lz > z0 and lz < z1 then
					local best, ax, q = lx - x0, 1, -1
					if x1 - lx < best then best, ax, q = x1 - lx, 1, 1 end
					if ly - y0 < best then best, ax, q = ly - y0, 2, -1 end
					if y1 - ly < best then best, ax, q = y1 - ly, 2, 1 end
					if lz - z0 < best then best, ax, q = lz - z0, 3, -1 end
					if z1 - lz < best then best, ax, q = z1 - lz, 3, 1 end
					if best <= PUSH_MOST then
						local e = q * (best + 2 * EPS)
						local dx, dy, dz = outof(o, ax == 1 and e or 0, ax == 2 and e or 0,
								ax == 3 and e or 0)
						self.skip = o
						local free = not self:blocked(box_of(pos[1] + dx, pos[2] + dy,
								pos[3] + dz, b.r, b.h), true)
						self.skip = nil
						if free then
							pos[1], pos[2], pos[3] = pos[1] + dx, pos[2] + dy, pos[3] + dz
							lx, ly, lz = into(o, pos[1] - o.x, pos[2] - o.y, pos[3] - o.z)
						end
					end
				end
			end
		end
	end
end

-- A body buried by an edit (voxels or the heightmap raised into it):
-- lifted to the lowest free place over it, up to UNBURY_M over its feet
-- ([KIT_PARAM_AUDIT] a World generated again under it: a noise ground
-- risen a dozen cells over a flat one's level; before, its height and a
-- cell, and the body stayed in the ground), never sideways. pos the body's
-- bottom middle, changed; true: lifted.
-- simplified: a body with no free place within the reach checks it all
-- each step (UNBURY_M * 2 boxes)
local UNBURY_M = 64
function W:unbury(pos, b)
	local x, y, z = pos[1], pos[2], pos[3]
	local g = self:ground_max(x - b.r, z - b.r, x + b.r, z + b.r)
	local cand = y
	if g and g > y + EPS then
		cand = g
	end
	-- (that far only with its middle in the solid: a body against a wall,
	-- its box into it, is lifted no further than before, not onto the top)
	local deep = self:blocked(box_of(x, y + b.h / 2, z, 0.05, 0.05), true)
	local top = y + (deep and math.max(b.h + 1, UNBURY_M) or b.h + 1)
	while cand <= top do
		if not self:blocked(box_of(x, cand, z, b.r, b.h)) then
			if cand == y then
				return false
			end
			pos[2] = cand
			return true
		end
		-- The next half cell over the bottom ([KIT_SLAB_WALK]: a slab's
		-- top, a cell's)
		cand = (floor(cand * 2 + EPS) + 1) / 2
	end
	return false
end

-- x and z, each as far as it goes; then the heightmap's ground under the
-- new footprint: climbed where its slope is within b.slope, else the move
-- back
function W:slide(b, dx, dz)
	local bx = box_of(b.x, b.y, b.z, b.r, b.h)
	local mx, hx = self:sweep(bx, 1, dx)
	bx[1], bx[4] = bx[1] + mx, bx[4] + mx
	local mz, hz = self:sweep(bx, 3, dz)
	local x, z, y = b.x + mx, b.z + mz, b.y
	local g = self:ground_max(x - b.r, z - b.r, x + b.r, z + b.r)
	if g and g > y then
		local dist = sqrt(mx * mx + mz * mz)
		-- Climbed from where it is, or the ground under it before
		local g0 = self:ground_max(b.x - b.r, b.z - b.r, b.x + b.r, b.z + b.r)
		if g - (g0 and g0 > y and g0 or y) <= dist * (b.slope or 1) + 0.02 and
				not self:blocked(box_of(x, g, z, b.r, b.h)) then
			y = g
		else
			return b.x, b.y, b.z, 0, 0, dx ~= 0 and 1 or nil, dz ~= 0 and 1 or nil
		end
	end
	return x, y, z, mx, mz, hx, hz
end

function W:move(b, dx, dy, dz, step)
	local hits = {x = 0, y = 0, z = 0}
	-- [KIT_PLANE] nothing across the plane (no wall met there, no step up from one;
	-- [KIT_TOP_DOWN] a level one: nothing up or down)
	if self.horizontal then
		dy, step = 0, 0
	elseif self.plane then
		dz = 0
	end
	local bb = box_of(b.x, b.y, b.z, b.r, b.h)
	local my, hy = self:sweep(bb, 2, dy)
	if hy then
		hits.y = dy < 0 and -1 or 1
		hits.y_info = hy
	end
	local sx, sy, sz = 0, 0, 0
	if my ~= 0 then
		sx, sy, sz = self:shed(b.x, b.y + my, b.z, b.r, b.h, my)
	end
	local s = {x = b.x + sx, y = b.y + my + sy, z = b.z + sz, r = b.r, h = b.h,
		slope = b.slope}
	local x, y, z, mx, mz, hx, hz = self:slide(s, dx, dz)
	-- [KIT_PLANE] stage 3: a polygon's edge is climbed as far as its slope is within
	-- b.slope (lifted as much as that slope takes over the move), else no step up it
	-- ([KIT_TOP_DOWN] (2) a flat one's edge is an upright wall: a voxel's step)
	local pe = type(hx) == "table" and hx.ny and not hx.flat and hx or
			type(hz) == "table" and hz.ny and not hz.flat and hz
	if pe and step and step > 0 then
		local k = b.slope or 1
		local up = sqrt(dx * dx + dz * dz) * k + 2 * EPS
		step = pe.ny > 0 and abs(pe.nx) <= pe.ny * k + 1e-9 and
				(up < step and up or step) or 0
	end
	-- Up a step where blocked: lifted, slid, put down again; taken if it
	-- went further
	if (hx or hz) and step and step > 0 then
		local up = self:sweep(box_of(s.x, s.y, s.z, b.r, b.h), 2, step)
		if up > EPS then
			local s2 = {x = s.x, y = s.y + up, z = s.z, r = b.r, h = b.h,
				slope = b.slope}
			local x2, y2, z2, mx2, mz2, hx2, hz2 = self:slide(s2, dx, dz)
			local down = self:sweep(box_of(x2, y2, z2, b.r, b.h), 2, -up - EPS)
			-- ([KIT_WALKER_FRAME] past a side leaning away it would be coming down
			-- inside the object)
			if mx2 * mx2 + mz2 * mz2 > mx * mx + mz * mz + 1e-8 and
					not self:blocked(box_of(x2, y2 + down, z2, b.r, b.h)) then
				x, y, z, mx, mz, hx, hz = x2, y2 + down, z2, mx2, mz2, hx2, hz2
			end
		end
	end
	if hx then
		hits.x = dx < 0 and -1 or 1
	end
	if hz then
		hits.z = dz < 0 and -1 or 1
	end
	return x - b.x, y - b.y, z - b.z, hits
end

-- A ray into a free object's frame: the nearest of its boxes, t and the axis it
-- came in by (nil: inside)
function ray_turned(ob, ox, oy, oz, dx, dy, dz, len)
	local lo = {into(ob, ox - ob.x, oy - ob.y, oz - ob.z)}
	local lv = {into(ob, dx, dy, dz)}
	local best, ba = nil, nil
	for _, f in ipairs(ob.b) do
		local t0, t1, na = 0, len, nil
		for k = 1, 3 do
			if abs(lv[k]) < 1e-9 then
				if lo[k] < f[k] or lo[k] > f[k + 3] then
					t0 = math.huge
				end
			else
				local a1, a2 = (f[k] - lo[k]) / lv[k], (f[k + 3] - lo[k]) / lv[k]
				if a1 > a2 then
					a1, a2 = a2, a1
				end
				if a1 > t0 then
					t0, na = a1, k
				end
				if a2 < t1 then
					t1 = a2
				end
			end
		end
		if t0 <= t1 and (not best or t0 < best) then
			best, ba = t0, na
		end
	end
	return best, ba
end

-- [KIT_AIRSHIPS] A ray at the free objects alone: t, the object, the cell hit in
-- its frame ({i, j, k}, a cell's middle its whole coordinates), the normal out of
-- that face and the ray's direction, both in its frame; skip: an object's id
-- passed through
function W:ray_objects(ox, oy, oz, dx, dy, dz, len, skip)
	local l = sqrt(dx * dx + dy * dy + dz * dz)
	if l < 1e-9 then
		return nil
	end
	dx, dy, dz = dx / l, dy / l, dz / l
	local best, bo, ba
	for _, ob in ipairs(self.turned) do
		local t0, na = nil, nil
		if ob.id ~= skip then
			t0, na = ray_turned(ob, ox, oy, oz, dx, dy, dz, len)
		end
		if t0 and na and (not best or t0 < best) then
			best, bo, ba = t0, ob, na
		end
	end
	if not best then
		return nil
	end
	local lo = {into(bo, ox - bo.x, oy - bo.y, oz - bo.z)}
	local lv = {into(bo, dx, dy, dz)}
	local n = {0, 0, 0}
	n[ba] = lv[ba] > 0 and -1 or 1
	local cell = {}
	for k = 1, 3 do
		cell[k] = floor(lo[k] + lv[k] * best - n[k] * 0.5 + 0.5)
	end
	return best, bo, cell, n, lv
end

-- A ray: the first solid cell (Amanatides and Woo), object box or ground
-- along it within len: t, info, the normal (no_ground: the heightmap left out)
function W:ray(ox, oy, oz, dx, dy, dz, len, no_ground)
	local l = sqrt(dx * dx + dy * dy + dz * dz)
	if l < 1e-9 then
		return nil
	end
	dx, dy, dz = dx / l, dy / l, dz / l
	local o, v = {ox, oy, oz}, {dx, dy, dz}
	local best, bi, bn = nil, nil, nil
	local c, st, tmax, td = {}, {}, {}, {}
	for k = 1, 3 do
		local p = o[k] + 0.5
		c[k] = floor(p)
		if v[k] > 1e-9 then
			st[k], tmax[k], td[k] = 1, (c[k] + 1 - p) / v[k], 1 / v[k]
		elseif v[k] < -1e-9 then
			st[k], tmax[k], td[k] = -1, (p - c[k]) / -v[k], -1 / v[k]
		else
			st[k], tmax[k], td[k] = 0, math.huge, math.huge
		end
	end
	local t, axis = 0, nil
	for _ = 1, 1024 do
		if t > len then
			break
		end
		local info = self:cell(c[1], c[2], c[3])
		if info and info.boxes then
			-- A shape: its boxes, the nearest hit (else on through it)
			for _, b in ipairs(cell_boxes(info, c[1], c[2], c[3])) do
				local t0, t1, na = 0, len, nil
				for q = 1, 3 do
					if abs(v[q]) < 1e-9 then
						if o[q] < b[q] or o[q] > b[q + 3] then
							t0 = math.huge
						end
					else
						local a1, a2 = (b[q] - o[q]) / v[q], (b[q + 3] - o[q]) / v[q]
						if a1 > a2 then
							a1, a2 = a2, a1
						end
						if a1 > t0 then
							t0, na = a1, q
						end
						if a2 < t1 then
							t1 = a2
						end
					end
				end
				if t0 <= t1 and (not best or t0 < best) then
					local n = {0, 0, 0}
					if na then
						n[na] = v[na] > 0 and -1 or 1
					end
					best, bi, bn = t0, info, n
				end
			end
			if best then
				break
			end
		elseif info then
			local n = {0, 0, 0}
			if axis then
				n[axis] = -st[axis]
			end
			best, bi, bn = t, info, n
			break
		end
		local k = 1
		if tmax[2] < tmax[k] then k = 2 end
		if tmax[3] < tmax[k] then k = 3 end
		t, axis = tmax[k], k
		c[k] = c[k] + st[k]
		tmax[k] = tmax[k] + td[k]
	end
	for _, b in ipairs(self.boxes) do
		local t0, t1, na = 0, len, nil
		for k = 1, 3 do
			if abs(v[k]) < 1e-9 then
				if o[k] < b[k] or o[k] > b[k + 3] then
					t0 = math.huge
				end
			else
				local a1, a2 = (b[k] - o[k]) / v[k], (b[k + 3] - o[k]) / v[k]
				if a1 > a2 then
					a1, a2 = a2, a1
				end
				if a1 > t0 then
					t0, na = a1, k
				end
				if a2 < t1 then
					t1 = a2
				end
			end
		end
		if t0 <= t1 and (not best or t0 < best) then
			local n = {0, 0, 0}
			if na then
				n[na] = v[na] > 0 and -1 or 1
			end
			best, bi, bn = t0, b.info or M.OBJECT, n
		end
	end
	for _, ob in ipairs(self.turned) do
		local t0, na = ray_turned(ob, ox, oy, oz, dx, dy, dz, len)
		if t0 and (not best or t0 < best) then
			local n = {0, 0, 0}
			if na then
				local lv = {into(ob, dx, dy, dz)}
				local q = lv[na] > 0 and -1 or 1
				n = {outof(ob, na == 1 and q or 0, na == 2 and q or 0,
						na == 3 and q or 0)}
			end
			best, bi, bn = t0, M.OBJECT, n
		end
	end
	if self.ground_fn and not no_ground then
		local stp, prev = 0.25, 0
		local lim = best or len
		local tt = 0
		while tt <= lim do
			local h = self.ground_fn(ox + dx * tt, oz + dz * tt)
			if h and oy + dy * tt < h then
				-- Bisected between the last point above and this one
				local a, b2 = prev, tt
				for _ = 1, 12 do
					local m = (a + b2) / 2
					local hm = self.ground_fn(ox + dx * m, oz + dz * m)
					if hm and oy + dy * m < hm then
						b2 = m
					else
						a = m
					end
				end
				best, bi, bn = b2, M.GROUND, {0, 1, 0}
				break
			end
			prev = tt
			tt = tt + stp
		end
	end
	if not best then
		return nil
	end
	return best, bi, bn[1], bn[2], bn[3]
end

-- How far down from x, y, z the first solid is (within len): the
-- distance and its info, or nil
function W:down(x, y, z, len)
	local i, k = floor(x + 0.5), floor(z + 0.5)
	local best, info = nil, nil
	local j = floor(y + 0.5)
	local top = j
	while top + 0.5 > y - len - 1 do
		local c = self:cell(i, top, k)
		local ctop = top + 0.5
		if c and c.boxes then
			-- A shape: the highest of its boxes under the point (none: on
			-- down through the cell)
			local hi = nil
			for _, o in ipairs(cell_boxes(c, i, top, k)) do
				if x >= o[1] and x <= o[4] and z >= o[3] and z <= o[6] and
						o[2] <= y + EPS and (not hi or o[5] > hi) then
					hi = o[5]
				end
			end
			if hi then
				ctop = hi
			else
				c = nil
			end
		end
		if c then
			-- Inside it: the top of the cell above it... a wall, 0
			local d = y - ctop
			if d < 0 then
				d = 0
			end
			if d <= len then
				best, info = d, c
			end
			break
		end
		top = top - 1
	end
	for _, b in ipairs(self.boxes) do
		if x >= b[1] and x <= b[4] and z >= b[3] and z <= b[6] and
				b[2] <= y then
			local d = y - b[5]
			if d < 0 then
				d = 0
			end
			if d <= len and (not best or d < best) then
				best, info = d, b.info or M.OBJECT
			end
		end
	end
	for _, o in ipairs(self.turned) do
		local d = ray_turned(o, x, y, z, 0, -1, 0, len)
		if d and (not best or d < best) then
			best, info = d, M.OBJECT
		end
	end
	-- [KIT_PLANE] stage 3: the polygons' tops (edges going +x: solid under them)
	-- through z, under the point
	for _, p in ipairs(self.polys) do
		-- ([KIT_TOP_DOWN] (2) a flat one's top face over the point)
		if p.da == 2 and p.z1 <= y + EPS and y - p.z1 <= len and p.x0 <= x and
				p.x1 >= x and p.y0 <= z and p.y1 >= z and poly_inside(p, x, z) then
			local d = y - p.z1
			if not best or d < best then
				best, info = d < 0 and 0 or d, p.info
			end
		elseif p.da ~= 2 and p.z0 < z and p.z1 > z and p.x0 <= x and p.x1 >= x and
				p.y0 <= y + EPS then
			local q = p.pts
			for i = 1, p.n do
				local j = i % p.n + 1
				local ax, bx = q[2 * i - 1], q[2 * j - 1]
				if ax < bx and ax <= x and bx >= x then
					local d = y - (q[2 * i] + (x - ax) * (q[2 * j] - q[2 * i]) / (bx - ax))
					if d > -EPS and d <= len and (not best or d < best) then
						best, info = d < 0 and 0 or d, edge_info(p, i)
					end
				end
			end
		end
	end
	local h = self:height(x, z)
	if h then
		local d = y - h
		if d < 0 then
			d = 0
		end
		if d <= len and (not best or d < best) then
			best, info = d, M.GROUND
		end
	end
	return best, info
end

-- ([KIT_TOP_DOWN] (2) a floor polygon there first: W:floor_at)
function W:under(x, y, z)
	local f = self:floor_at(x, y, z)
	if f then
		return f
	end
	local _, info = self:down(x, y, z, 0.6)
	return info
end

-- [KIT_TOP_DOWN] (2) The info of the floor polygon under the point: over its area,
-- the point no lower than its bottom and at most 0.6 over its top (the highest top
-- of those); nil: none
function W:floor_at(x, y, z)
	local top, info = nil, nil
	for _, p in ipairs(self.floors) do
		if p.z0 <= y + EPS and y - p.z1 <= 0.6 and (not top or p.z1 > top) and
				p.x0 <= x and p.x1 >= x and p.y0 <= z and p.y1 >= z and
				poly_inside(p, x, z) then
			top, info = p.z1, p.info
		end
	end
	return info
end

-- What touches the body (b = {x, y, z, r, h}): each side's within 0.05
function W:contacts(b)
	local out = {}
	local bb = box_of(b.x, b.y, b.z, b.r, b.h)
	for a = 1, 3 do
		for _, sgn in ipairs({-1, 1}) do
			local d, info = self:sweep(bb, a, sgn * 0.05)
			if info then
				local n = {0, 0, 0}
				n[a] = -sgn
				out[#out + 1] = {info, n[1], n[2], n[3], dist = abs(d)}
			end
		end
	end
	return out
end

-- ---- [KIT_PLANE] The plane (the top of this file says what)
-- The body held to it after a step: its depth, its speed across; on a free object's
-- deck its feet there follow. simplified: the speed in a deck's frame is the deck's
-- own (a turned deck's across is left; the depth is put back each step)
function W:hold(s)
	local p, v = s.pos, s.vel
	if type(p) ~= "table" then
		return
	end
	-- ([KIT_TOP_DOWN] a level one: the feet at its cell's bottom)
	local a = self.horizontal and 2 or 3
	p[a] = self.horizontal and self.plane - 0.5 or self.plane
	if s.frame and type(s.at) == "table" then
		for _, o in ipairs(self.turned) do
			if o.id == s.frame then
				s.at = {into(o, p[1] - o.x, p[2] - o.y, p[3] - o.z)}
			end
		end
	elseif type(v) == "table" then
		v[a] = 0
	end
end

-- The edges in the plane at z, each {ax, ay, bx, by, info} with the solid on its
-- right going from a to b, for x0...x1, y0...y1: the heightmap's profile along z (a
-- vertex at each whole x: exact at a whole z, as the plane's is) and the outlines of
-- the polygons spanning z (stage 3)
-- ([KIT_TOP_DOWN] a level plane at y = z: the flat polygons', no heightmap's)
function W:plane_edges(z, x0, y0, x1, y1)
	local out = {}
	local da = self.horizontal and 2 or 3
	for _, p in ipairs(self.polys) do
		if (p.da or 3) == da and p.z0 < z and p.z1 > z and p.x0 <= x1 and p.x1 >= x0 and
				p.y0 <= y1 and p.y1 >= y0 then
			local q = p.pts
			for i = 1, p.n do
				local j = i % p.n + 1
				local ax, ay, bx, by = q[2 * i - 1], q[2 * i], q[2 * j - 1], q[2 * j]
				if (ax < bx and ax or bx) <= x1 and (ax > bx and ax or bx) >= x0 and
						(ay < by and ay or by) <= y1 and (ay > by and ay or by) >= y0 then
					out[#out + 1] = {ax, ay, bx, by, edge_info(p, i), poly = true}
				end
			end
		end
	end
	if self.ground_fn and not self.horizontal then
		local px, ph = nil, nil
		for ix = floor(x0), floor(x1) + 1 do
			local h = self.ground_fn(ix, z)
			if h and ph then
				out[#out + 1] = {px, ph, ix, h, M.GROUND}
			end
			px, ph = ix, h
		end
	end
	return out
end

-- The circle's contacts, the deepest first (the same one twice once)
function W:circle(x, y, r, z)
	z = z or self.plane or 0
	local k = floor(z + 0.5)
	local out = {}
	-- [KIT_TOP_DOWN] the plane's 2D y the world's V, across it N; a 2D cell's in the
	-- world
	local hz = self.horizontal
	local V, N = hz and 3 or 2, hz and 2 or 3
	local function cell(i, j)
		if hz then
			return self:cell(i, k, j)
		end
		return self:cell(i, j, k)
	end
	local function add(d, nx, ny, info)
		local at = #out + 1
		for i, c in ipairs(out) do
			if abs(c.depth - d) < 1e-9 and abs(c.nx - nx) < 1e-9 and
					abs(c.ny - ny) < 1e-9 then
				return
			end
			if at > #out and d > c.depth then
				at = i
			end
		end
		for i = #out, at, -1 do
			out[i + 1] = out[i]
		end
		out[at] = {depth = d, nx = nx, ny = ny, info = info}
	end
	-- A box x0...x1, y0...y1; f: its sides that are surfaces ({-x, +x, -y, +y}: past
	-- one that is not, against a solid neighbour, the box goes on)
	local ALL = {true, true, true, true}
	local function box(x0, y0, x1, y1, f, info)
		local qx = x < x0 and f[1] and x0 or x > x1 and f[2] and x1 or x
		local qy = y < y0 and f[3] and y0 or y > y1 and f[4] and y1 or y
		local dx, dy = x - qx, y - qy
		local d2 = dx * dx + dy * dy
		if d2 > 0 then
			if d2 < r * r then
				local d = sqrt(d2)
				add(r - d, dx / d, dy / d, info)
			end
			return
		end
		if x < x0 or x > x1 or y < y0 or y > y1 then
			return
		end
		-- The middle in it: out by its nearest surface (buried: its nearest side)
		local best, nx, ny = nil, 0, 0
		for pass = 1, 2 do
			for q, s in ipairs({{x - x0, -1, 0}, {x1 - x, 1, 0}, {y - y0, 0, -1},
					{y1 - y, 0, 1}}) do
				if (f[q] or pass == 2) and (not best or s[1] < best) then
					best, nx, ny = s[1], s[2], s[3]
				end
			end
			if best then
				break
			end
		end
		add(r + best, nx, ny, info)
	end
	local function full(i, j)
		local c = cell(i, j)
		return c ~= nil and not c.boxes
	end
	for i = lo_cell(x - r), hi_cell(x + r) do
		for j = lo_cell(y - r), hi_cell(y + r) do
			local info = cell(i, j)
			if info and info.boxes then
				for _, b in ipairs(cell_boxes(info, i, hz and k or j, hz and j or k)) do
					if b[N] < z and b[N + 3] > z then
						box(b[1], b[V], b[4], b[V + 3], ALL, info)
					end
				end
			elseif info then
				box(i - 0.5, j - 0.5, i + 0.5, j + 0.5, {not full(i - 1, j),
					not full(i + 1, j), not full(i, j - 1), not full(i, j + 1)}, info)
			end
		end
	end
	for _, b in ipairs(self.boxes) do
		if b[N] < z and b[N + 3] > z and b[1] < x + r and b[4] > x - r and b[V] < y + r and
				b[V + 3] > y - r then
			box(b[1], b[V], b[4], b[V + 3], ALL, b.info or M.OBJECT)
		end
	end
	-- [KIT_TOP_DOWN] (8) the other bodies: circles (one on the middle: out along +x)
	for _, b in ipairs(self.bodies or {}) do
		local dx, dy, rr = x - b[1], y - b[2], r + b[3]
		local d2 = dx * dx + dy * dy
		if d2 < rr * rr then
			local d = sqrt(d2)
			if d > 1e-9 then
				add(rr - d, dx / d, dy / d, b.info)
			else
				add(rr, 1, 0, b.info)
			end
		end
	end
	-- The edges: from in front as from a box's corner; from behind (inside the solid,
	-- over the edge's span) out along its normal
	for _, e in ipairs(self:plane_edges(z, x - r, y - r, x + r, y + r)) do
		local ax, ay, ex, ey = e[1], e[2], e[3] - e[1], e[4] - e[2]
		local l2 = ex * ex + ey * ey
		if l2 > 1e-18 then
			local u = ((x - ax) * ex + (y - ay) * ey) / l2
			local cu = u < 0 and 0 or u > 1 and 1 or u
			local dx, dy = x - ax - ex * cu, y - ay - ey * cu
			local l = sqrt(l2)
			local nx, ny = -ey / l, ex / l
			local side = dx * nx + dy * ny
			local d2 = dx * dx + dy * dy
			if side > 0 and d2 < r * r then
				local d = sqrt(d2)
				add(r - d, dx / d, dy / d, e[5])
			elseif side <= 0 and u >= 0 and u <= 1 and (not e.poly or side > -r) then
				-- (a polygon's: within r behind it; deeper, its far side's would
				-- push the wrong way)
				add(r - side, nx, ny, e[5])
			end
		end
	end
	return out
end

-- [KIT_SMALL_PIECES] A circle (a wheel, a ball) moving at vx, vy out of what it
-- meets: pushed out of the deepest hit, its speed into it gone (e the share
-- bounced back), friction along it (mu times the hit's info.friction times the
-- push back, at most what stops it sliding), then again while another hit is
-- still in, 4 rounds at most. Each hit it pushed out of has vn, the speed into
-- it before (negative: coming in). hits: each round's w:circle hits in turn (one
-- may be there twice)
function W:resolve_circle(x, y, r, vx, vy, e, mu, z)
	e, mu = tonumber(e) or 0, tonumber(mu) or 0
	local all = {}
	for _ = 1, 4 do
		local hits = self:circle(x, y, r, z)
		local h = hits[1]
		if not h then
			break
		end
		for _, o in ipairs(hits) do
			all[#all + 1] = o
		end
		local nx, ny = h.nx, h.ny
		x, y = x + nx * h.depth, y + ny * h.depth
		local vn = vx * nx + vy * ny
		h.vn = vn
		if vn < 0 then
			local j = -(1 + e) * vn
			-- (along t = (-ny, nx))
			local vt = vy * nx - vx * ny
			local lim = mu * (h.info and tonumber(h.info.friction) or 1) * j
			local jt = vt > lim and lim or vt < -lim and -lim or vt
			vx, vy = vx + nx * j + ny * jt, vy + ny * j - nx * jt
		end
		-- (another still in after this push: a round more)
		local again = false
		for k = 2, #hits do
			local o = hits[k]
			if o.depth - h.depth * (nx * o.nx + ny * o.ny) > EPS then
				again = true
				break
			end
		end
		if not again then
			break
		end
	end
	return x, y, vx, vy, all
end

-- The first solid along the segment
function W:segment(x0, y0, x1, y1, z)
	z = z or self.plane or 0
	local dx, dy = x1 - x0, y1 - y0
	local len = sqrt(dx * dx + dy * dy)
	if len < 1e-12 then
		return nil
	end
	local t, info, nx, ny, _
	if self.horizontal then
		-- ([KIT_TOP_DOWN] level: along x and z at y = z; the normal's x and z)
		t, info, nx, _, ny = self:ray(x0, z, y0, dx, 0, dy, len, true)
	else
		t, info, nx, ny = self:ray(x0, y0, z, dx, dy, 0, len, true)
	end
	local best = t and t / len
	for _, e in ipairs(self:plane_edges(z, x0 < x1 and x0 or x1, y0 < y1 and y0 or y1,
			x0 < x1 and x1 or x0, y0 < y1 and y1 or y0)) do
		local ex, ey = e[3] - e[1], e[4] - e[2]
		local den = dx * ey - dy * ex
		if abs(den) > 1e-12 then
			local ax, ay = e[1] - x0, e[2] - y0
			local s = (ax * ey - ay * ex) / den
			local u = (ax * dy - ay * dx) / den
			if s >= 0 and s <= 1 and u >= 0 and u <= 1 and (not best or s < best) then
				local l = sqrt(ex * ex + ey * ey)
				best, info, nx, ny = s, e[5], -ey / l, ex / l
				if nx * dx + ny * dy > 0 then
					nx, ny = -nx, -ny
				end
			end
		end
	end
	if not best then
		return nil
	end
	return best, nx, ny, info
end

-- ---- A character: kit/walker's and kit/click_to_move's step. s the
-- state (s.pos, s.vel; s.ground, s.friction and s.surface of what it
-- stands on, s.coyote, s.buffer, s.held, s.jumps: the jumps counted), b
-- the body {r, h}, wx, wz the wished velocity (m/s), jump the button
-- (held: it jumps again on landing), p the parameters: acceleration,
-- gravity, jump_height (0: no jump), air_control, coyote_time,
-- jump_buffer, step_height, slope_limit (degrees)
local function num(v, d)
	return type(v) == "number" and v or d
end

-- Toward a wish on the plane: at most acc this step
local function toward(v, wx, wz, acc)
	local dx, dz = wx - v[1], wz - v[3]
	local l = sqrt(dx * dx + dz * dz)
	if l > acc and l > 0 then
		dx, dz = dx * acc / l, dz * acc / l
	end
	v[1], v[3] = v[1] + dx, v[3] + dz
end

-- A jump pressed up to jump_buffer before the ground, taken up to coyote_time
-- after it: true when it is taken now, its speed up left to the caller
local function jump_taken(s, ground, jump, dt, p)
	if ground then
		s.coyote = num(p.coyote_time, 0.1)
	end
	if jump and (not s.held or ground) then
		s.buffer = num(p.jump_buffer, 0.12)
	end
	s.held = jump and true or false
	local taken = false
	if num(p.jump_height, 1.6) > 0 and num(s.buffer, 0) > 0 and
			num(s.coyote, 0) > 0 then
		s.buffer, s.coyote = 0, 0
		s.jumps = num(s.jumps, 0) + 1
		ground, taken = false, true
	end
	s.buffer = num(s.buffer, 0) - dt
	if s.buffer < 0 then s.buffer = 0 end
	if not ground then
		s.coyote = num(s.coyote, 0) - dt
		if s.coyote < 0 then s.coyote = 0 end
	end
	return taken
end

-- [KIT_WALKER_FRAME] An object's frame as a world: its boxes the flat voxels. The
-- rest of the world (the cells, looks, heightmap, other objects) has its say on
-- each move: the body upright at its feet there, swept along the move in the
-- world; the deck's own frame goes no further. A floor it reaches is remembered
-- (W:walk_on leaves for it).
local function frame_sweep(f, b, a, d)
	local got, hit = W.sweep(f, b, a, d)
	if got == 0 then
		return 0, hit
	end
	local w, o = f.outer, f.o
	local x, y, z = outof(o, (b[1] + b[4]) / 2, b[2], (b[3] + b[6]) / 2)
	local wb = box_of(x + o.x, y + o.y, z + o.z, (b[4] - b[1]) / 2, b[5] - b[2])
	local m = {outof(o, a == 1 and got or 0, a == 2 and got or 0,
			a == 3 and got or 0)}
	local t = 1
	w.skip = o
	for q = 1, 3 do
		if abs(m[q]) > 1e-9 then
			local g, info = w:sweep(wb, q, m[q])
			if info and g / m[q] < t then
				t, hit = g / m[q], info
			end
			if info and q == 2 and m[2] < 0 then
				f.floor = true
			end
		end
	end
	w.skip = nil
	return got * t, hit
end

function W:frame_world(o)
	self.frames = self.frames or {}
	local f = self.frames[o]
	if not f then
		f = M.world{cell = function() return nil end, boxes = o.b}
		f.cell, f.sweep, f.outer, f.o = f.cell_fn, frame_sweep, self, o
		self.frames[o] = f
	end
	f.floor = false
	return f
end

-- The frame left: the body's velocity the world's. simplified: nothing carries a
-- walker up off a high edge (its velocity up dropped: a deck is no ramp to launch
-- from). [KIT_MOVING_OBJECTS] A moving deck's velocity at the feet added: what it
-- leaves with in the world, kept through the air (s.carry, W:walk) until it lands
local function leave_frame(w, s, o)
	local v = s.vel
	local x, y, z = outof(o, v[1], v[2], v[3])
	local dx, dy, dz = w:deck_velocity(o, s.pos[1], s.pos[2], s.pos[3])
	s.vel = {x + dx, (y > 0 and 0 or y) + dy, z + dz}
	s.frame, s.at = nil, nil
	s.carry = o.links and {dx, dz} or nil
end

-- A step in the frame of o: true; false: it jumped, out of the frame, and the
-- world's step goes on with it
function W:walk_on(o, s, b, wx, wz, jump, dt, p)
	local f = self:frame_world(o)
	if type(s.at) ~= "table" then
		s.at = {into(o, s.pos[1] - o.x, s.pos[2] - o.y, s.pos[3] - o.z)}
	end
	local at, v = s.at, s.vel
	if f:unbury(at, b) and v[2] < 0 then
		v[2] = 0
	end
	-- [KIT_MOVING_OBJECTS] Carried into the world (a deck rolled into the ground, a
	-- course through a wall): off it, the world's step goes on from there, out by
	-- unbury. simplified: carrying is no sweep, so a fast deck can take a body
	-- through a thin wall; a sweep of the feet from the last pose is the upgrade
	if o.links then
		local x, y, z = outof(o, at[1], at[2], at[3])
		x, y, z = x + o.x, y + o.y, z + o.z
		self.skip = o
		local in_world = self:blocked(box_of(x, y, z, b.r, b.h), true)
		self.skip = nil
		if in_world then
			s.pos[1], s.pos[2], s.pos[3] = x, y, z
			leave_frame(self, s, o)
			s.ground = false
			return false
		end
	end
	local g = num(p.gravity, 15)
	-- The world's up in the frame
	local R = o.R
	local ux, uy, uz = R[4], R[5], R[6]
	local flat = uy >= M.cos(num(p.slope_limit, 45) * PI / 180)
	local ground = s.ground == true
	-- The wish: what goes that way in the world, level, along the deck, at its
	-- speed (straight down the world's up onto the deck)
	local sp = sqrt(wx * wx + wz * wz)
	local lx, ly, lz = into(o, wx, 0, wz)
	local lift = uy > 1e-3 and -ly / uy or 0
	lx, lz = lx + lift * ux, lz + lift * uz
	local l = sqrt(lx * lx + lz * lz)
	if l > 1e-9 then
		lx, lz = lx * sp / l, lz * sp / l
	end
	local acc = num(p.acceleration, 40) * dt
	if flat then
		toward(v, lx, lz, acc * (ground and num(s.friction, 1) or
				num(p.air_control, 0.6)))
	else
		-- Past the limit: gravity along the deck; no walking up it, sideways as
		-- in the air
		local tx, tz = -g * ux, -g * uz
		v[1], v[3] = v[1] + tx * dt, v[3] + tz * dt
		local tl = sqrt(tx * tx + tz * tz)
		if tl > 0 then
			local sx, sz = -tz / tl, tx / tl
			local want = lx * sx + lz * sz - v[1] * sx - v[3] * sz
			local most = acc * num(p.air_control, 0.6)
			want = want > most and most or want < -most and -most or want
			v[1], v[3] = v[1] + sx * want, v[3] + sz * want
		end
		ground = false
	end
	if jump_taken(s, ground, jump, dt, p) then
		local x, y, z = outof(o, at[1], at[2], at[3])
		s.pos[1], s.pos[2], s.pos[3] = x + o.x, y + o.y, z + o.z
		leave_frame(self, s, o)
		s.vel[2] = s.vel[2] + sqrt(2 * g * num(p.jump_height, 1.6))
		s.ground = false
		return false
	end
	v[2] = v[2] - g * uy * dt
	local speed = sqrt(v[1] * v[1] + v[2] * v[2] + v[3] * v[3])
	if speed > 60 then
		v[1], v[2], v[3] = v[1] * 60 / speed, v[2] * 60 / speed, v[3] * 60 / speed
	end
	local body = {x = at[1], y = at[2], z = at[3], r = b.r, h = b.h}
	local mx, my, mz, hits = f:move(body, v[1] * dt, v[2] * dt, v[3] * dt,
			ground and num(p.step_height, 0.6) or 0)
	at[1], at[2], at[3] = at[1] + mx, at[2] + my, at[3] + mz
	if hits.x ~= 0 then v[1] = 0 end
	if hits.z ~= 0 then v[3] = 0 end
	local on = nil
	if hits.y ~= 0 then
		v[2] = 0
		if hits.y < 0 then
			on = hits.y_info
		end
	end
	if not on then
		local d, info = f:sweep(box_of(at[1], at[2], at[3], b.r, b.h), 2,
				-num(p.step_height, 0.6))
		if info then
			at[2] = at[2] + d
			v[2] = 0
			on = info
		end
	end
	local x, y, z = outof(o, at[1], at[2], at[3])
	s.pos[1], s.pos[2], s.pos[3] = x + o.x, y + o.y, z + o.z
	-- The world's floor under the feet, or nothing: the world's again
	local floor = false
	if f.floor then
		self.skip = o
		local _, info = self:sweep(box_of(s.pos[1], s.pos[2], s.pos[3], b.r, b.h),
				2, -0.02)
		self.skip = nil
		floor = info ~= nil
	end
	if not on or floor then
		leave_frame(self, s, o)
		s.ground, s.friction, s.surface = false, nil, nil
		return true
	end
	s.ground = flat
	s.friction = flat and on.friction or nil
	s.surface = on.surface
	return true
end

-- [KIT_TOP_DOWN] (1) W:walk in a level plane: toward the wish as what is under the
-- feet lets (w:under's friction, 1 over nothing), along x and z only; always on its
-- floor (s.ground), s.friction and s.surface w:under's after the move.
-- simplified: no free object's deck (s.frame), no step up
function W:walk_flat(s, b, wx, wz, dt, p)
	local pos, v = s.pos, s.vel
	s.frame, s.at, s.carry = nil, nil, nil
	local on = self:under(pos[1], pos[2], pos[3])
	toward(v, wx, wz, num(p.acceleration, 40) * dt * (on and on.friction or 1))
	v[2] = 0
	local mx, _, mz, hits = self:move({x = pos[1], y = pos[2], z = pos[3], r = b.r,
		h = b.h}, v[1] * dt, 0, v[3] * dt, 0)
	pos[1], pos[3] = pos[1] + mx, pos[3] + mz
	if hits.x ~= 0 then v[1] = 0 end
	if hits.z ~= 0 then v[3] = 0 end
	on = self:under(pos[1], pos[2], pos[3])
	s.ground = true
	s.friction = on and on.friction or 1
	s.surface = on and on.surface or nil
	return s
end

-- [KIT_AUTO_JUMP] auto (the input's): up a one-voxel step without Jump
M.AUTOJUMP_HEIGHT = 1.1
M.AUTOJUMP_S = 0.1
function W:walk(s, b, wx, wz, jump, dt, p, auto)
	if type(s.pos) ~= "table" then
		s.pos = {0, 0, 0}
	end
	if type(s.vel) ~= "table" then
		s.vel = {0, 0, 0}
	end
	-- [KIT_TOP_DOWN] (1) a level plane: no gravity, no jump
	if self.horizontal then
		return self:walk_flat(s, b, wx, wz, dt, p)
	end
	-- [KIT_PLANE] no wish across the plane
	if self.plane then
		wz = 0
	end
	-- [KIT_WALKER_FRAME] On an object: in its frame. Its object gone (taken away
	-- in an edit): the world's, where it stood
	if s.frame then
		local o = nil
		for _, t in ipairs(self.turned) do
			if t.id == s.frame then
				o = t
			end
		end
		-- A knock from the server (kit.cpp's knock()): out, its speed the world's
		local push = s.push
		s.push = nil
		if o and type(push) == "table" then
			leave_frame(self, s, o)
			for k = 1, 3 do
				s.vel[k] = s.vel[k] + (tonumber(push[k]) or 0)
			end
			s.ground = false
		elseif o and self:walk_on(o, s, b, wx, wz, jump, dt, p) then
			return s
		elseif not o then
			s.frame, s.at = nil, nil
		end
	end
	local pos, v = s.pos, s.vel
	if self.moving then
		self:pushed(pos, b)
	end
	if self:unbury(pos, b) and v[2] < 0 then
		v[2] = 0
	end
	local g = num(p.gravity, 15)
	local jh = num(p.jump_height, 1.6)
	local ground = s.ground == true
	-- Toward the wished velocity: on the ground as its friction lets, in
	-- the air as air_control does ([KIT_MOVING_OBJECTS] over what a moving deck
	-- gave it, so that a jump keeps up with the deck)
	local carry = not ground and type(s.carry) == "table" and s.carry or nil
	-- [KIT_AUTO_JUMP] the jump auto jump chose, held a moment
	if num(s.auto_t, 0) > 0 then
		s.auto_t = s.auto_t - dt
		jump = true
	end
	toward(v, wx + (carry and num(carry[1], 0) or 0), wz + (carry and num(carry[2], 0) or 0),
			num(p.acceleration, 40) * dt * (ground and num(s.friction, 1)
			or num(p.air_control, 0.6)))
	local jumped = jump_taken(s, ground, jump, dt, p)
	if jumped then
		v[2] = sqrt(2 * g * jh)
		ground = false
	end
	v[2] = v[2] - g * dt
	if v[2] < -60 then v[2] = -60 end
	local vy = v[2]
	local lim = num(p.slope_limit, 45) * PI / 180
	local body = {x = pos[1], y = pos[2], z = pos[3], r = b.r, h = b.h,
		slope = M.sin(lim) / M.cos(lim)}
	local mx, my, mz, hits = self:move(body, v[1] * dt, v[2] * dt, v[3] * dt,
			ground and num(p.step_height, 0.6) or 0)
	-- [KIT_AUTO_JUMP] Walking on the ground into what the step does not take:
	-- a jump when the same move from AUTOJUMP_HEIGHT up (room over the head)
	-- gets further (Luanti's LocalPlayer::handleAutojump), held AUTOJUMP_S
	if auto and ground and not jump and not jumped and (hits.x ~= 0 or
			hits.z ~= 0) and (wx ~= 0 or wz ~= 0) then
		local up = self:sweep(box_of(body.x, body.y, body.z, b.r, b.h), 2,
				M.AUTOJUMP_HEIGHT)
		if up >= M.AUTOJUMP_HEIGHT - EPS then
			local _, _, _, jx, jz = self:slide({x = body.x, y = body.y + up,
				z = body.z, r = b.r, h = b.h, slope = body.slope}, v[1] * dt,
				v[3] * dt)
			if jx * jx + jz * jz > (mx * mx + mz * mz) * 1.01 + 1e-12 then
				s.auto_t = M.AUTOJUMP_S
			end
		end
	end
	pos[1], pos[2], pos[3] = pos[1] + mx, pos[2] + my, pos[3] + mz
	if hits.x ~= 0 then v[1] = 0 end
	if hits.z ~= 0 then v[3] = 0 end
	local on = nil
	if hits.y ~= 0 then
		v[2] = 0
		if hits.y < 0 then
			on = hits.y_info
		end
	end
	-- Off an edge walking: down a step, not into the air
	if not on and ground and not jumped then
		local d, info = self:sweep(box_of(pos[1], pos[2], pos[3], b.r, b.h), 2,
				-num(p.step_height, 0.6))
		if info then
			pos[2] = pos[2] + d
			v[2] = 0
			on = info
		end
	end
	-- The heightmap's ground climbed: on it
	if not on and my >= 0 and self.ground_fn then
		local gm = self:ground_max(pos[1] - b.r, pos[3] - b.r, pos[1] + b.r,
				pos[3] + b.r)
		if gm and gm >= pos[2] - EPS and v[2] <= 0 then
			on = M.GROUND
			v[2] = 0
		end
	end
	-- [KIT_SURVIVAL_TUNING] a landing's speed (the fastest of the steps since
	-- the server last took it: kit.cpp's fall_hurt)
	if on and not ground and -vy > num(s.impact, 0) then
		s.impact = -vy
	end
	s.ground = on ~= nil
	-- ([KIT_TOP_DOWN] (2) a floor polygon over the ground: its surface)
	local fl = on and self:floor_at(pos[1], pos[2], pos[3]) or on
	s.friction = on and fl.friction or nil
	s.surface = on and fl.surface or nil
	if on then
		s.carry = nil
	end
	-- [KIT_WALKER_FRAME] On an object's top: into its frame, what it landed with
	-- going along the deck (past [KIT_MOVING_OBJECTS] a moving deck's own velocity).
	-- simplified: a top only; an object turned over stands a
	-- body on its other faces in the world's frame, which holds it where it hit;
	-- choosing the face nearest the world's up as the frame's floor is the upgrade
	local o = on and on.frame
	if o and o.R[5] > 0.02 then
		s.frame = o.id
		s.at = {into(o, pos[1] - o.x, pos[2] - o.y, pos[3] - o.z)}
		local dx, dy, dz = self:deck_velocity(o, pos[1], pos[2], pos[3])
		s.vel = {into(o, v[1] - dx, v[2] - dy, v[3] - dz)}
		s.vel[2] = 0
		s.ground = o.R[5] >= M.cos(lim)
		s.friction = s.ground and 1 or nil
	end
	return s
end

-- ---- Heights: builtin/heightmap's height_at() over its samples
-- (sample(ix, iz) -> the height there, nil past the map), the same
-- triangles
function M.height(sample, x, z)
	local ix, iz = floor(x), floor(z)
	local xf, zf = x - ix, z - iz
	local h1, h2, h3
	if xf + zf >= 1 then
		h1, h2, h3 = sample(ix + 1, iz + 1), sample(ix, iz + 1),
				sample(ix + 1, iz)
		xf, zf = 1 - xf, 1 - zf
	else
		h1, h2, h3 = sample(ix, iz), sample(ix + 1, iz), sample(ix, iz + 1)
	end
	if not h1 or not h2 or not h3 then
		return nil
	end
	return h1 * (1 - xf - zf) + h2 * xf + h3 * zf
end

-- ---- The server's world: what kit.cpp sends a step (a box of cells round
-- the body, a char each, x fastest, then z, then y: "." air, "?" not
-- loaded, "A"... its classes {name, solid, friction, surface, boxes (a
-- shape's, [KIT_VOXEL_FORMAT]; a class a facing)}; the solid
-- looks near {look, on, {x, y, z}, yaw[, pitch, roll]}; a heightmap's samples
-- round it)
function M.snapshot(t)
	-- [KIT_VEHICLE_MOVEMENTS] the steered ones' keys
	M.tracks = type(t.tracks) == "table" and t.tracks or {}
	local classes = {}
	for i, c in ipairs(t.classes or {}) do
		classes[i] = M.voxel_info(c[1], c[2], c[3], c[4], c[5])
	end
	local cells, x0, y0, z0 = t.cells or "", t.x0 or 0, t.y0 or 0, t.z0 or 0
	local nx, ny, nz = t.nx or 0, t.ny or 0, t.nz or 0
	local function cell(i, j, k)
		local a, b, c = i - x0, j - y0, k - z0
		if a < 0 or b < 0 or c < 0 or a >= nx or b >= ny or c >= nz then
			return nil
		end
		local ch = cells:byte(1 + a + nx * (c + nz * b))
		if ch == 63 then
			return M.UNKNOWN
		elseif not ch or ch < 65 then
			return nil
		end
		return classes[ch - 64]
	end
	local boxes, moving_looks, polys = {}, nil, {}
	for _, l in ipairs(t.looks or {}) do
		-- [KIT_MOVING_OBJECTS] on a moving object: placed as each step's time has it
		if l[7] then
			moving_looks = moving_looks or {}
			l[2] = l[2] == true
			moving_looks[#moving_looks + 1] = l
		else
			local b = M.look_box(l[1], l[2] == true, l[3], l[4], l[5], l[6])
			if b then
				boxes[#boxes + 1] = b
			end
			-- [KIT_PLANE] stage 3
			local p = M.look_poly(l[1], l[2] == true, l[3], l[4], l[5], l[6])
			if p then
				polys[#polys + 1] = p
			end
		end
	end
	local ground = nil
	local hm = t.hm
	if type(hm) == "table" then
		local function sample(ix, iz)
			local a, c = ix - hm.x0, iz - hm.z0
			if a < 0 or c < 0 or a >= hm.nx or c >= hm.nz then
				return nil
			end
			return hm.h[1 + a + hm.nx * c]
		end
		ground = function(x, z)
			return M.height(sample, x, z)
		end
	end
	-- [KIT_HM_ORIGIN] the map from its origin's world cell
	local edge = type(hm) == "table" and hm.sx and {hm.ox or 0, hm.oz or 0,
			(hm.ox or 0) + hm.sx - 1, (hm.oz or 0) + hm.sz - 1} or nil
	return M.world{cell = cell, boxes = boxes, ground = ground, edge = edge,
		turned = M.turned(t.turned or {}), moving_looks = moving_looks, t = t.t,
		plane = t.plane, horizontal = t.horizontal, polys = polys, bodies = t.bodies}
end

-- The steps of a batch: each input dt long, in sub steps of its own
-- ([KIT_MOVING_OBJECTS] the world's moving objects as each has them: i.t its stamp, ms)
-- [KIT_PLANE] stage 4: s.events, nil before each step, what the steps set there
-- after them (MAX_EVENTS at most); guard(true) and guard(false) round each
-- def.step: the box's per-step cap
M.MAX_EVENTS = 16
-- [KIT_MOVE_DRAW] movement.pose = {"name"...}: the slots' names (8 at most,
-- the rest and a name that is no plain string or is a slot's number left
-- out); nil: none
function M.pose_names(d)
	if type(d) ~= "table" then
		return nil
	end
	local names = {}
	for k = 1, 8 do
		local n = d[k]
		if type(n) ~= "string" or not n:match("^[%a_][%w_]*$") then
			break
		end
		names[k] = n
	end
	return #names > 0 and names or nil
end
-- s.pose after a step, written by name or by index, as the numbers in slot
-- order (what is kept, sent and stepped on: the wire's as ever); a slot it
-- left out 0, the indices past the names as they were
local function pose_slots(names, s)
	local p = s.pose
	if type(p) ~= "table" then
		return
	end
	local out = {}
	for k, n in ipairs(names) do
		local v = p[n]
		if v == nil then
			v = p[k]
		end
		out[k] = v == nil and 0 or v
	end
	local k = #names + 1
	while p[k] ~= nil do
		out[k] = p[k]
		k = k + 1
	end
	s.pose = out
end
-- What a draw gets of a pose (the numbers in slot order): the slots by index
-- and by name alike
function M.pose_view(names, pose)
	local v = {}
	for k, x in ipairs(type(pose) == "table" and pose or {}) do
		v[k] = x
	end
	for k, n in ipairs(names or {}) do
		v[n] = v[k]
	end
	return v
end
function M.steps(def, s, inputs, dt, sub, w, p, guard)
	sub = sub or 1
	local names = M.pose_names(type(def.movement) == "table" and def.movement.pose)
	local events = nil
	for _, i in ipairs(inputs) do
		for n = 1, sub do
			if w.moving and i.t then
				w:pose_at(i.t / 1000 + (n - 1) * dt / sub)
			end
			s.events = nil
			if guard then
				guard(true)
			end
			def.step(s, i, dt / sub, w, p)
			if guard then
				guard(false)
			end
			if names then
				pose_slots(names, s)
			end
			if type(s.events) == "table" then
				events = events or {}
				for _, e in ipairs(s.events) do
					if #events < M.MAX_EVENTS then
						events[#events + 1] = e
					end
				end
			end
			if w.plane then
				w:hold(s)
			end
		end
	end
	s.events = events
	return s
end

-- ---- [KIT_CLIENT_REACT] (1) Zones as kit.cpp meets them (its ZoneShape,
-- look_zone, body_shape and zone_meets, ported line by line): the client's
-- own predicted body against the zones of the entities with client parts
-- (module.lua's update_zones), the server still the one that decides. A turn
-- is a 3x3 matrix (rows); a shape {kind = "c" cells, "b" a turned box, "s" a
-- sphere, "p" a polygon over its depth; o, R, n, a, b, r, pts, lo, hi}.
-- simplified: client-only, though the box loads the file too (a few hundred
-- lines it never calls)
local function tr(R)
	return {R[1], R[4], R[7], R[2], R[5], R[8], R[3], R[6], R[9]}
end
local function app(R, v)
	return {R[1] * v[1] + R[2] * v[2] + R[3] * v[3],
		R[4] * v[1] + R[5] * v[2] + R[6] * v[3],
		R[7] * v[1] + R[8] * v[2] + R[9] * v[3]}
end
local ID = {1, 0, 0, 0, 1, 0, 0, 0, 1}

-- A node's rotation (w, x, y, z) as a matrix; nil: none (the identity)
function M.quat_matrix(w, x, y, z)
	if abs(x) < 1e-7 and abs(y) < 1e-7 and abs(z) < 1e-7 then
		return nil
	end
	return {1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y),
		2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x),
		2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y)}
end

local function bound(z)
	z.lo, z.hi = {math.huge, math.huge, math.huge}, {-math.huge, -math.huge, -math.huge}
	for c = 0, 7 do
		local v = app(z.R, {c % 2 == 1 and z.b[1] or z.a[1],
			floor(c / 2) % 2 == 1 and z.b[2] or z.a[2], c >= 4 and z.b[3] or z.a[3]})
		for k = 1, 3 do
			v[k] = v[k] + z.o[k]
			if v[k] < z.lo[k] then z.lo[k] = v[k] end
			if v[k] > z.hi[k] then z.hi[k] = v[k] end
		end
	end
	return z
end

-- A box of n cells (a position parameter's zone) from the entity at pos
-- turned by R (nil: level, on the cell its place floors to: box_frame's)
function M.zone_cells(pos, R, n)
	local o = {pos[1], pos[2], pos[3]}
	if not R then
		for k = 1, 3 do o[k] = floor(o[k]) end
	end
	local nn = {}
	for k = 1, 3 do
		nn[k] = type(n) == "table" and tonumber(n[k]) or 1
	end
	return bound({kind = "c", o = o, R = R or ID, n = nn, a = {-0.5, -0.5, -0.5},
		b = {nn[1] - 0.5, nn[2] - 0.5, nn[3] - 0.5}})
end

local function num(v, i, def)
	local x = type(v) == "table" and tonumber(v[i])
	return x and x == x and x ~= math.huge and x ~= -math.huge and x or def
end

-- zone = "look": the entity's look (show.look: its params in it) at pos
-- turned by R, its `when` while on, as look_zone has it; nil: none.
-- [KIT_TOP_DOWN] (3) a polygon met in its own frame however turned: lying flat
-- (pitch 90), its outline over the world's x and z, its depth along y
-- (kit_plane_check.lua's flat L)
function M.zone_look(look, on, pos, R)
	if type(look) ~= "table" then
		return nil
	end
	R = R or ID
	local wh = on and type(look.when) == "table" and look.when or {}
	local o = {pos[1], pos[2], pos[3]}
	if look.shape == "polygon" then
		local sc, wo = {}, {}
		for k = 1, 3 do
			sc[k], wo[k] = num(wh.scale, k, 1), num(wh.offset, k, 0)
		end
		wo = app(R, wo)
		for k = 1, 3 do o[k] = o[k] + wo[k] end
		local pts = {}
		for _, p in ipairs(type(look.points) == "table" and look.points or {}) do
			pts[#pts + 1] = num(p, 1, 0) * sc[1]
			pts[#pts + 1] = num(p, 2, 0) * sc[2]
		end
		if #pts < 6 then
			return nil
		end
		local d = tonumber(look.depth) or 1
		local r = (d < 0.02 and 0.02 or d > 64 and 64 or d) / 2 * abs(sc[3])
		local a, b = {pts[1], pts[2], -r}, {pts[1], pts[2], r}
		for i = 1, #pts - 1, 2 do
			for k = 1, 2 do
				local v = pts[i + k - 1]
				if v < a[k] then a[k] = v end
				if v > b[k] then b[k] = v end
			end
		end
		return bound({kind = "p", o = o, R = R, pts = pts, r = r, a = a, b = b})
	end
	local size, off = {}, {}
	for k = 1, 3 do
		if type(look.size) == "table" then
			local v = num(look.size, k, 1)
			size[k] = v < 0.02 and 0.02 or v > 64 and 64 or v
		else
			size[k] = math.min(128, abs((tonumber(look.size) or 0.4) * 2))
		end
		off[k] = num(look.offset, k, 0) + num(wh.offset, k, 0)
	end
	if type(wh.scale) == "table" then
		for k = 1, 3 do
			local was = size[k]
			size[k] = size[k] * num(wh.scale, k, 1)
			if k == 2 then
				off[2] = off[2] - (was - size[2]) / 2
			end
		end
	end
	if wh.swing == true then
		local hinge = off[1] - size[1] / 2
		local front, back = off[3] - size[3] / 2, off[3] + size[3] / 2
		size[1], size[3] = size[3], size[1]
		off[1] = hinge + size[1] / 2
		off[3] = wh.mirror == true and back - size[3] / 2 or front + size[3] / 2
	end
	local rv = look.rotation
	local RR = m3(R, rotation(num(rv, 1, 0), num(rv, 2, 0), num(rv, 3, 0)))
	off = app(RR, off)
	for k = 1, 3 do o[k] = o[k] + off[k] end
	if look.shape == "sphere" and size[1] == size[2] and size[2] == size[3] then
		local r = size[1] / 2
		return bound({kind = "s", o = o, R = ID, r = r, a = {-r, -r, -r}, b = {r, r, r}})
	end
	return bound({kind = "b", o = o, R = RR, a = {-size[1] / 2, -size[2] / 2,
		-size[3] / 2}, b = {size[1] / 2, size[2] / 2, size[3] / 2}})
end

-- The body as the zones meet it (body_shape): its movement's spheres
-- ({x, y, z, r} from the feet, 8 at most, each within 16 m, r 0.01...8),
-- else its body's box (box: {r, h}, a movement's zone = "box"), else its
-- point half a metre over the feet
function M.zone_body(feet, spheres, box)
	local p = {feet[1], feet[2] + 0.5, feet[3]}
	local s = {p = p, spheres = {}, lo = {p[1], p[2], p[3]}, hi = {p[1], p[2], p[3]}}
	for _, c in ipairs(type(spheres) == "table" and spheres or {}) do
		if #s.spheres >= 8 then
			break
		end
		local ok = type(c) == "table" and #c == 4
		for k = 1, 4 do
			local v = ok and tonumber(c[k])
			ok = v and v == v and (k < 4 and abs(v) <= 16 or k == 4 and v >= 0.01 and v <= 8)
		end
		if ok then
			local q = {c[1] + feet[1], c[2] + feet[2], c[3] + feet[3], c[4]}
			s.spheres[#s.spheres + 1] = q
			for k = 1, 3 do
				if q[k] - q[4] < s.lo[k] then s.lo[k] = q[k] - q[4] end
				if q[k] + q[4] > s.hi[k] then s.hi[k] = q[k] + q[4] end
			end
		end
	end
	if #s.spheres > 0 or type(box) ~= "table" then
		return s
	end
	local function cl(v, d, a, b)
		v = tonumber(v) or d
		return v < a and a or v > b and b or v
	end
	local r, h, EPS = cl(box.r, 0.45, 0.05, 8), cl(box.h, 1.7, 0.05, 16), 1e-3
	s.box = true
	for k = 1, 3 do
		s.lo[k] = feet[k] - (k == 2 and 0 or r) + EPS
		s.hi[k] = feet[k] + (k == 2 and h or r) - EPS
	end
	return s
end

local function in_outline(q, x, y)
	local inside, n = false, #q / 2
	local j = n
	for i = 1, n do
		local xi, yi, xj, yj = q[2 * i - 1], q[2 * i], q[2 * j - 1], q[2 * j]
		if (yi > y) ~= (yj > y) and x < xi + (y - yi) * (xj - xi) / (yj - yi) then
			inside = not inside
		end
		j = i
	end
	return inside
end

local function zone_d2(z, p)
	local l = app(tr(z.R), {p[1] - z.o[1], p[2] - z.o[2], p[3] - z.o[3]})
	if z.kind == "s" then
		local d = sqrt(l[1] * l[1] + l[2] * l[2] + l[3] * l[3]) - z.r
		return d > 0 and d * d or 0
	end
	if z.kind ~= "p" then
		local d2 = 0
		for k = 1, 3 do
			local d = l[k] < z.a[k] and z.a[k] - l[k] or l[k] > z.b[k] and l[k] - z.b[k] or 0
			d2 = d2 + d * d
		end
		return d2
	end
	local dz = math.max(0, abs(l[3]) - z.r)
	if in_outline(z.pts, l[1], l[2]) then
		return dz * dz
	end
	local best, q, n = math.huge, z.pts, #z.pts / 2
	local j = n
	for i = 1, n do
		local ax, ay = q[2 * j - 1], q[2 * j]
		local ex, ey = q[2 * i - 1] - ax, q[2 * i] - ay
		local ll = ex * ex + ey * ey
		local t = ll > 0 and ((l[1] - ax) * ex + (l[2] - ay) * ey) / ll or 0
		t = t < 0 and 0 or t > 1 and 1 or t
		local dx, dy = ax + ex * t - l[1], ay + ey * t - l[2]
		if dx * dx + dy * dy < best then best = dx * dx + dy * dy end
		j = i
	end
	return dz * dz + best
end

local function zone_box(z, lo, hi)
	if z.kind == "s" then
		local d2 = 0
		for k = 1, 3 do
			local c = math.max(lo[k], math.min(hi[k], z.o[k]))
			d2 = d2 + (c - z.o[k]) * (c - z.o[k])
		end
		return d2 < z.r * z.r
	end
	local la, lb = {math.huge, math.huge, math.huge}, {-math.huge, -math.huge, -math.huge}
	local inv = tr(z.R)
	for c = 0, 7 do
		local v = app(inv, {(c % 2 == 1 and hi[1] or lo[1]) - z.o[1],
			(floor(c / 2) % 2 == 1 and hi[2] or lo[2]) - z.o[2],
			(c >= 4 and hi[3] or lo[3]) - z.o[3]})
		for k = 1, 3 do
			if v[k] < la[k] then la[k] = v[k] end
			if v[k] > lb[k] then lb[k] = v[k] end
		end
	end
	if z.kind ~= "p" then
		for k = 1, 3 do
			if lb[k] <= z.a[k] or la[k] >= z.b[k] then
				return false
			end
		end
		return true
	end
	if lb[3] <= -z.r or la[3] >= z.r then
		return false
	end
	local q, n = z.pts, #z.pts / 2
	for i = 1, n do
		local x, y = q[2 * i - 1], q[2 * i]
		if x > la[1] and x < lb[1] and y > la[2] and y < lb[2] then
			return true
		end
	end
	if in_outline(q, (la[1] + lb[1]) / 2, (la[2] + lb[2]) / 2) then
		return true
	end
	local j = n
	for i = 1, n do
		local s = {q[2 * j - 1], q[2 * j]}
		local d = {q[2 * i - 1] - s[1], q[2 * i] - s[2]}
		local t0, t1, out = 0, 1, false
		for k = 1, 2 do
			if out then break end
			if abs(d[k]) < 1e-12 then
				out = s[k] <= la[k] or s[k] >= lb[k]
			else
				local u, w = (la[k] - s[k]) / d[k], (lb[k] - s[k]) / d[k]
				if u > w then u, w = w, u end
				t0, t1 = math.max(t0, u), math.min(t1, w)
				out = t0 >= t1
			end
		end
		if not out then
			return true
		end
		j = i
	end
	return false
end

-- Whether a body (M.zone_body's) meets a zone: its bounds first, then its
-- spheres, its box or its point (a point in cells as box_holds has it)
function M.zone_meets(z, s)
	if z.kind == "c" and not s.box and #s.spheres == 0 then
		local l = app(tr(z.R), {s.p[1] - z.o[1], s.p[2] - z.o[2], s.p[3] - z.o[3]})
		for k = 1, 3 do
			local c = floor(l[k] + 0.5)
			if c < 0 or c >= z.n[k] then
				return false
			end
		end
		return true
	end
	for k = 1, 3 do
		if s.hi[k] < z.lo[k] or s.lo[k] > z.hi[k] then
			return false
		end
	end
	for _, c in ipairs(s.spheres) do
		local near = true
		for k = 1, 3 do
			near = near and c[k] + c[4] >= z.lo[k] and c[k] - c[4] <= z.hi[k]
		end
		if near and zone_d2(z, c) < c[4] * c[4] then
			return true
		end
	end
	if #s.spheres > 0 then
		return false
	end
	if s.box then
		return zone_box(z, s.lo, s.hi)
	end
	return zone_d2(z, s.p) <= 0
end

return M
-- vim: set noet ts=4 sw=4:
