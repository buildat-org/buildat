-- Buildat: extensions/voxel_light/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- **A voxel world's light in pbr** ([LC_SKY_SHARED] 2), over
-- extensions/physical_sky's sky:
--   new_vis()  how much of the sky the camera can see in each direction,
--              marched through the voxels: the cube the shaders' SkyVis
--              reads, the chamber reading, the sky overhead
--   terms(), apply(), object_light(), lamp_curve()  the light a face
--              gets, onto whatever sets it
-- It loads nothing of its own: the caller hands in the engine (magic,
-- buildat), the voxels (collect) and the sky (physical_sky), so the one
-- source runs bundled (luanti_client's require) and served (voxel_shading
-- names it in its meta.json's client_extensions, builtin/luanti and
-- skeldat run their server's copy).

local M = {}
-- The interface the sandbox's require hands out
M.safe = M

-- How much of the sky the camera can see, per direction, as a cube of 6x6
-- values per face: 216 numbers, which the shader samples along a pixel's
-- reflection direction and multiplies the sky cube map by. That is the whole
-- indoor/outdoor treatment. There is no second, dimmed cube map to fade to
-- any more, and no single blend value deciding which one a surface gets: this
-- dims the real sky in the directions it cannot be seen and leaves it alone
-- in the directions it can, which is what a baked indoor map was
-- approximating and it cannot get the geometry wrong. Standing in a tunnel
-- mouth, the walls stop reflecting sky while the mouth still does; looking at
-- a cave from outside with no sky in view, nothing reflects a horizon band
-- that is not there.
--
-- 6x6 rather than something coarser because the openings that matter are
-- small: the sky over a tunnel is a few degrees off the tunnel's own
-- direction. A cell here is about 15 degrees across, where a 3x3 cube's is 40
-- and the shader's interpolation spreads one cell over most of a face; the
-- self-check's flat ground reads 0.50 to the sides at this resolution and
-- 0.92 at 3x3, where the ground and the sky above it end up in the same cell.
--
-- The values come from marching rays through the voxel data from the camera.
-- No geometry, depth buffer or render pass is involved. buildat.cast_voxel_rays
-- does the marching, on a worker thread, which is what makes this many rays
-- affordable: the same loop written in Lua cost half a millisecond a frame for
-- four rays of twenty voxels, where the engine marches one in a third of a
-- microsecond. It also decides what stops a ray by the voxel registry's own
-- physically_solid, so glass and water are whatever the world says they are.
--
-- Handing the rays over costs several times more than marching them does --
-- see the note in apps/sample_lighting_scene/README.txt for where the time goes, and
-- for why making the marching itself faster would be the wrong thing to try.
--
-- A ray answers no if something solid stops it, and otherwise the skylight of
-- the air it ended in. Partial values come from sampling rather
-- than from any softening of that: the rays are jittered within their cells
-- and differently each sweep, and each cell keeps an average of its own rays,
-- so a cell settles at the fraction of its directions that see sky.
local FACES = 6
local CELLS = 6                -- Per face, per axis; keep in step with the
                               -- shader's SKYVIS_CELLS
local CELL_COUNT = FACES * CELLS * CELLS
-- Rays cast into each cell per sweep, averaged into that cell's value. This is
-- the knob for how noisy one sweep's answer is: a cell's rays are yes or no,
-- so one of them is a coin flip weighted by how much of the cell sees sky, and
-- the average of K of them has a K-th of the variance. They are stratified
-- within the cell rather than independent, so they cover it evenly instead of
-- clumping the way K independent samples would.
local RAYS_PER_CELL = 4
-- Cells refreshed per frame. A sweep is every cell once, so this is how often
-- the whole cube is renewed: 36 cells of the 216 here is a sweep every six
-- frames, or every three at the rate MAX_IN_FLIGHT actually keeps up -- read
-- its comment before taking this or RAYS_PER_CELL as rays per frame.
local CELLS_PER_UPDATE = 36
-- How far a ray looks. Long, because the length is what makes the answer
-- strict: a ray down demo_digger's tunnel has to reach the end of it to find out
-- that the tunnel is not a way to the sky, and the tunnel is tens of voxels
-- long. Cheap enough that this is not the thing to save on.
local RAY_VOXELS = 64
-- How much of a cell's new value is taken into the one the shader sees. What a
-- sweep hands over is already an average of RAYS_PER_CELL rays; this averages
-- those over time as well. At 0.10 a cell settles in about a second and the
-- reflections trail the camera by about that. Taking more of each sweep puts
-- the sampling's own noise on the screen, which reads as the speculars
-- flickering several times a second.
local SKY_VIS_BLEND = 0.10
-- Sweeps averaged when snapping, for a camera that has been moved rather than
-- has moved: the same averaging done at once, so a screenshot taken right
-- after a teleport is as settled as one taken later. Two rather than more
-- because a sweep is already RAYS_PER_CELL deep. This is some thousands of
-- rays in one frame and drops one, which is what a teleport does anyway.
local SNAP_SWEEPS = 2

-- Slices out on worker threads, oldest first. The marching is the same work
-- wherever it runs; what moves it off the frame is that the frame has better
-- uses for a third of a millisecond, and that the sampling wants several times
-- more rays than that.
--
-- More than one is kept in flight because a slice submitted in one frame is
-- collected in a later one: with a single slice out, every other frame would
-- have nothing to collect and nothing to submit, and the sweep would take
-- twice as long for no reason. Two is enough to keep a worker fed. The pool
-- has four of them and the mesher is the other caller.
--
-- Note what this does to the rate. The queue is topped back up to this depth
-- every frame, so when the workers keep up, two slices are submitted per frame
-- and the rays cast are twice CELLS_PER_UPDATE times RAYS_PER_CELL: 288 a
-- frame where those two constants read 144. Worth knowing before reading
-- either of them as a rate.
local MAX_IN_FLIGHT = 2

-- The values go on the render path's scene pass commands rather than on
-- materials. Urho hands a scene pass command's shader parameters to every
-- batch that command draws, so this reaches the whole scene however many
-- chunks are loaded; a copy per material was hundreds of calls a sweep and
-- cost more than the ray marching did.
--
-- Two steps, because the cheap way to set it is not the way to declare it.
-- RenderPath:SetShaderParameter() only touches commands that already carry the
-- name, and that is the per frame path: three calls, no matter how long the
-- render path is. Adding the name to the scene passes means walking the
-- commands, and each command asked for is a fresh sandbox wrapper, which came
-- to a third of a millisecond a frame; so the walk happens now and then
-- instead. A game that swaps its render path -- they clone one and append post
-- processing to it -- gets the name back on the next walk, and until then the
-- shader keeps the values it had.
--
-- The commands themselves are deliberately not kept: they are pointers into a
-- vector the render path can reallocate.
local DECLARE_EVERY_FRAMES = 60

M.RAY_VOXELS = RAY_VOXELS
M.CELL_COUNT = CELL_COUNT
-- The +Y face's cells, 1-based: the face the shader indexes as 2
local ABOVE_FIRST = 2 * CELLS * CELLS + 1
local ABOVE_LAST = 3 * CELLS * CELLS
-- Eight of 216, about a twentieth of the sphere; see chamber()
local BEST_CELLS = 8

-- Which way a cell looks. A direction is placed on the cube by its largest
-- component: that component picks the face, and the other two, divided by it,
-- are the position on the face in -1..1. Going the other way, as here, the
-- face's own axis is +-1 and the other two are the cell's position. The
-- shader takes a direction apart exactly this way, so the two only have to
-- agree with each other and not with anyone's cube map face convention.
--
-- Face f is axis (f - f % 2) / 2 -- 0 x, 1 y, 2 z -- and sign 1 for even f,
-- -1 for odd. u runs along the lowest-numbered axis that is not the face's
-- own and v along the highest.
local FACE_AXES = {
	{major = "x", u = "y", v = "z", sign =  1},
	{major = "x", u = "y", v = "z", sign = -1},
	{major = "y", u = "x", v = "z", sign =  1},
	{major = "y", u = "x", v = "z", sign = -1},
	{major = "z", u = "x", v = "y", sign =  1},
	{major = "z", u = "x", v = "y", sign = -1},
}

local AXIS_OFFSET = {x = 0, y = 1, z = 2}
local CELL_SIZE = 2.0 / CELLS

-- Where in its cell each ray of this sweep samples.
--
-- Two parts: a fixed offset per cell, and a step the whole sweep takes. The
-- step is two irrationals, so a cell's sample point walks its cell instead of
-- landing on a few spots, and the sequence is the same every run.
--
-- The per-cell offset is the part that matters for what this looks like. With
-- one offset for the whole cube, every cell samples the same relative point at
-- the same time and their errors line up: a sweep whose offset happens to lean
-- towards the sky brightens every cell that straddles an opening at once, so
-- the reflections in the whole scene move together rather than each surface
-- wobbling on its own. Coherent like that it reads as the scene pulsing, which
-- is far more visible than the same amount of noise spread over cells, and
-- since the step is a fixed sequence the pulsing is periodic. More rays does
-- not help: it is not a shortage of samples, it is every cell making the same
-- error at the same moment.
--
-- The offsets are the R2 low discrepancy sequence over the cells, which spreads
-- them evenly in the square rather than clumping the way independent random
-- ones would. The sweep step is the golden ratio and root two, unrelated to R2
-- so the two do not come back into step with each other.
local CELL_JITTER_U = {}
local CELL_JITTER_V = {}
for i = 1, CELL_COUNT do
	CELL_JITTER_U[i] = (i * 0.7548776662) % 1.0
	CELL_JITTER_V[i] = (i * 0.5698402909) % 1.0
end
local SWEEP_STEP_U = 0.6180339887
local SWEEP_STEP_V = 0.4142135624

-- Where a cell's rays sit relative to each other: a Hammersley set, which
-- covers the cell evenly. The set is then shifted as a whole by the cell's own
-- offset and by the sweep's step, which keeps the even coverage while moving
-- it, so no two cells sample the same relative points and no cell samples the
-- same points twice.
local function radical_inverse_2(n)
	local r, f = 0.0, 0.5
	while n > 0 do
		r = r + (n % 2) * f
		n = math.floor(n / 2)
		f = f * 0.5
	end
	return r
end

local STRAT_U = {}
local STRAT_V = {}
for k = 1, RAYS_PER_CELL do
	STRAT_U[k] = (k - 0.5) / RAYS_PER_CELL
	STRAT_V[k] = radical_inverse_2(k - 1)
end

-- A ray answers 1 if nothing stopped it and 0 if something solid did.
--
-- Deliberately a yes or no. What a reflection wants to know is what lies in
-- that direction, and if the answer is rock three voxels away then it is rock,
-- however brightly lit the air in between happens to be. Partial values come
-- from the sampling, not from softening this.
--
-- What a ray is worth is the engine's rule now, since averaging rays into a
-- cell means deciding that: nothing if something solid stopped it, otherwise
-- the skylight of the air it ended in. See ray_visibility() in
-- src/lua_bindings/voxel_volume.cpp for why it is there and what it means.
--
-- Note what that rule does not do: stop a ray at full skylight. Skylight says
-- the sky is open above a point, which is nothing to do with whether the sky
-- lies along the ray, and stopping rays on it looked right and was badly wrong
-- -- at the mouth of demo_digger's tunnel the air is fully lit, so every direction
-- including the tunnel came back at 1. At the far end of a ray it answers
-- about the place the ray reached, which is a question it can answer.

-- Which cell a direction belongs to, 1-based, the way the shader places one:
-- the largest component picks the face and the other two, divided by it, are
-- the position on it. Only the self-check uses this; the sweep goes the other
-- way. Exposed so that the check is of the same arithmetic the shader does.
function M.cell_of(x, y, z)
	local ax, ay, az = math.abs(x), math.abs(y), math.abs(z)
	local face, u, v, major
	if ax >= ay and ax >= az then
		face = x > 0 and 1 or 2; major = ax; u, v = y, z
	elseif ay >= az then
		face = y > 0 and 3 or 4; major = ay; u, v = x, z
	else
		face = z > 0 and 5 or 6; major = az; u, v = x, y
	end
	if major <= 0 then return nil end
	local function cell_index(t)
		local c = math.floor((t / major + 1.0) / CELL_SIZE)
		return math.max(0, math.min(CELLS - 1, c))
	end
	local col, row = cell_index(u), cell_index(v)
	return ((face - 1) * CELLS + row) * CELLS + col + 1
end

-- **The camera's sky visibility** ([LC_SKY_SHARED] 2): the cube above.
--   local vis = voxel_light.new_vis(magic, buildat, collect, params)
--   vis:update(origin, dt)   -- every frame; dt of nil snaps
-- collect(origin) returns the voxel data to march through, as
--   {chunk_size = {x=, y=, z=}, registry = <VoxelRegistry>,
--    volumes = {{x=, y=, z=, volume = <Volume>}, ...}}
-- or nil for "no data near here", which is answered as open sky. It is
-- called once a sweep, not once a frame. params: the other shader
-- parameters to keep on the same scene passes, by name (set_param()).
function M.new_vis(magic, buildat, collect, params)
	local self = {}

	-- The directions, three numbers to a ray, in cell order: one flat array
	-- rather than a table per ray, because the engine reads every one of them
	-- every frame and a table each was most of what the sampling cost.
	local dirs = {}
	for i = 1, CELL_COUNT * RAYS_PER_CELL * 3 do
		dirs[i] = 0.0
	end

	-- What the shader is using now, and what the sweep in progress has found.
	-- Starting fully lit: a world that has not arrived yet looks like it is
	-- outdoors, which it usually is.
	local sky_vis = {}
	local sweep_vis = {}
	for i = 1, CELL_COUNT do
		sky_vis[i] = 1.0
		sweep_vis[i] = 1.0
	end
	local sweep_next = 1
	local sweep_index = 0
	local declare_countdown = 0
	local in_flight = {}
	local sky_vis_buffer = magic.VectorBuffer:new()
	local sky_vis_param = nil
	local sky_vis_dirty = false
	-- Other shader parameters that belong on the same scene passes, by name.
	-- The sky colour the reflections are multiplied by is one; it is set when
	-- the sky changes, and pushed with the visibility because getting a
	-- parameter onto the render path is the same walk either way.
	params = params or {SpecEmphasis = 1.0}
	-- Called with the render path on each walk that declares the names, for
	-- what goes on the passes other than by name (voxel_shading's area
	-- field); see self:redeclare()
	self.on_declare = nil

	-- The one table handed to buildat.cast_voxel_rays, reused: only the slice
	-- bounds, the origin and the volumes change between calls
	local ray_args = {
		directions = dirs,
		max_steps = RAY_VOXELS,
		-- Not used: skylight says the sky is open above a voxel, which is
		-- nothing to do with whether the sky lies along the ray
		stop_skylight = 0,
		-- Consecutive rays are one cell's, and the engine hands back their
		-- average per cell rather than what each of them found
		rays_per_cell = RAYS_PER_CELL,
		first = 1,
		count = 1,
		origin = {x = 0, y = 0, z = 0},
		volumes = {},
	}
	local have_volumes = false

	local function aim_dirs(index)
		local su = (index * SWEEP_STEP_U) % 1.0
		local sv = (index * SWEEP_STEP_V) % 1.0
		local i = 1
		for face = 1, FACES do
			local a = FACE_AXES[face]
			local mo = AXIS_OFFSET[a.major] + 1
			local uo = AXIS_OFFSET[a.u] + 1
			local vo = AXIS_OFFSET[a.v] + 1
			for row = 0, CELLS - 1 do
				for col = 0, CELLS - 1 do
					local bu = CELL_JITTER_U[i] + su
					local bv = CELL_JITTER_V[i] + sv
					local base = (i - 1) * RAYS_PER_CELL * 3
					for k = 1, RAYS_PER_CELL do
						local ju = (bu + STRAT_U[k]) % 1.0 - 0.5
						local jv = (bv + STRAT_V[k]) % 1.0 - 0.5
						dirs[base + mo] = a.sign
						dirs[base + uo] = (col + 0.5 + ju) * CELL_SIZE - 1.0
						dirs[base + vo] = (row + 0.5 + jv) * CELL_SIZE - 1.0
						base = base + 3
					end
					i = i + 1
				end
			end
		end
	end

	local function begin_sweep()
		sweep_next = 1
		sweep_index = sweep_index + 1
		aim_dirs(sweep_index)
	end
	begin_sweep()

	-- What the caller has to hand over, once a sweep. An empty answer is a
	-- world that has not arrived: outdoors is the right answer for it.
	local function take_volumes(origin)
		local got = collect(origin)
		if got == nil or got.volumes[1] == nil then
			have_volumes = false
			return false
		end
		ray_args.chunk_size = got.chunk_size
		ray_args.registry = got.registry
		ray_args.volumes = got.volumes
		have_volumes = true
		return true
	end

	local function keep_slice(first_cell, count_cells, out)
		local vis = out.visibility
		for c = 1, count_cells do
			sweep_vis[first_cell + c - 1] = vis[c]
		end
	end

	-- f is how much of the sweep's rays to take; 1.0 replaces the values
	local function blend_cells(first, count, f)
		for i = first, first + count - 1 do
			sky_vis[i] = sky_vis[i] + (sweep_vis[i] - sky_vis[i]) * f
		end
		sky_vis_dirty = true
	end

	local function sweep_all_open()
		for i = 1, CELL_COUNT do
			sweep_vis[i] = 1.0
		end
	end

	local function aim_args(first_cell, count_cells)
		ray_args.first = (first_cell - 1) * RAYS_PER_CELL + 1
		ray_args.count = count_cells * RAYS_PER_CELL
	end

	local function submit_slice(first_cell, count_cells)
		aim_args(first_cell, count_cells)
		in_flight[#in_flight + 1] = {first = first_cell, count = count_cells,
				job = buildat.cast_voxel_rays_start(ray_args)}
	end

	-- Blends in what has finished, oldest first, and stops at the first slice
	-- that has not: they are taken in the order they were cast.
	local function collect_slices(f)
		while in_flight[1] ~= nil do
			local slice = in_flight[1]
			local out = buildat.cast_voxel_rays_collect(slice.job)
			if out == nil then
				return
			end
			table.remove(in_flight, 1)
			keep_slice(slice.first, slice.count, out)
			blend_cells(slice.first, slice.count, f)
		end
	end

	-- Anything in flight is reading volumes it holds itself, so dropping the
	-- handles is enough; what they find is no longer wanted
	local function drop_slices()
		for i = #in_flight, 1, -1 do
			in_flight[i] = nil
		end
	end

	-- The values go on the render path's scene pass commands rather than on
	-- materials: Urho hands a scene pass command's shader parameters to every
	-- batch it draws, so this reaches every chunk in one call instead of
	-- hundreds. Declaring the name means walking the commands, which is not
	-- cheap enough for every frame, so that happens now and then and the
	-- per-frame path only updates the commands that already carry it.
	local function push()
		if sky_vis_dirty then
			sky_vis_dirty = false
			buildat.write_floats(sky_vis_buffer, sky_vis)
			sky_vis_param = magic.Variant(sky_vis_buffer)
		end
		if sky_vis_param == nil then return end
		local viewport = magic.renderer:GetViewport(0)
		if viewport == nil then return end
		local render_path = viewport.renderPath
		if render_path == nil then return end
		declare_countdown = declare_countdown - 1
		if declare_countdown <= 0 then
			declare_countdown = DECLARE_EVERY_FRAMES
			for i = 0, render_path:GetNumCommands() - 1 do
				local command = render_path:GetCommand(i)
				if command ~= nil and command.type == magic.CMD_SCENEPASS then
					command:SetShaderParameter("SkyVis", sky_vis_param)
					for name, value in pairs(params) do
						command:SetShaderParameter(name, value)
					end
				end
			end
			if self.on_declare then
				self.on_declare(render_path)
			end
			return
		end
		render_path:SetShaderParameter("SkyVis", sky_vis_param)
		for name, value in pairs(params) do
			render_path:SetShaderParameter(name, value)
		end
	end

	-- A shader parameter to keep on the scene passes along with the
	-- visibility; see params above
	function self:set_param(name, value)
		params[name] = value
		-- On the next frame rather than at the next declaring walk, so a sky
		-- that changes colour does not wait a second for it
		declare_countdown = 0
	end

	-- The names walked onto the passes again on the next frame
	function self:redeclare()
		declare_countdown = 0
	end

	-- dt of nil snaps, for a camera that has been moved rather than has
	-- moved: the same averaging done at once, so a screenshot taken right
	-- after a teleport is as settled as one taken later.
	function self:update(origin, dt)
		ray_args.origin.x = origin.x
		ray_args.origin.y = origin.y
		ray_args.origin.z = origin.z
		if dt == nil then
			-- What is out on a worker was cast from where the camera used to
			-- be, and blending it in afterwards would undo part of the snap
			drop_slices()
			for sweep = 1, SNAP_SWEEPS do
				begin_sweep()
				if take_volumes(origin) then
					aim_args(1, CELL_COUNT)
					keep_slice(1, CELL_COUNT,
							buildat.cast_voxel_rays(ray_args))
				else
					sweep_all_open()
				end
				blend_cells(1, CELL_COUNT, sweep == 1 and 1.0 or 1.0 / sweep)
			end
			begin_sweep()
			push()
			return
		end
		-- Each frame's cells are handed to the shader as their own rays land,
		-- rather than a whole sweep at a time: waiting for the sweep steps
		-- every reflection in the scene together, six frames apart.
		collect_slices(SKY_VIS_BLEND)
		while #in_flight < MAX_IN_FLIGHT do
			if sweep_next == 1 and not take_volumes(origin) then
				sweep_all_open()
				blend_cells(1, CELL_COUNT, SKY_VIS_BLEND)
				begin_sweep()
				break
			end
			local first = sweep_next
			local count = math.min(CELLS_PER_UPDATE, CELL_COUNT - sweep_next + 1)
			submit_slice(first, count)
			sweep_next = sweep_next + count
			if sweep_next > CELL_COUNT then
				begin_sweep()
			end
		end
		push()
	end

	-- What the shader is being told, for the counters and the self-check
	function self:value_of(cell)
		return sky_vis[cell]
	end

	-- The most sky any direction sees, nought in a sealed place
	function self:most()
		local m = 0
		for i = 1, CELL_COUNT do
			if sky_vis[i] > m then m = sky_vis[i] end
		end
		return m
	end

	function self:has_volumes()
		return have_volumes
	end

	-- The whole cube's mean, and its lowest and highest cell: what the
	-- reflections are gated by per direction, which chamber() cannot say --
	-- that is the mean of the eight brightest and reads 1.0 while most of
	-- the sphere is dark ([UNDERGROUND_LIGHT], 2026-09-28).
	function self:stats()
		local sum, lo, hi = 0, 1e9, -1e9
		for i = 1, CELL_COUNT do
			local v = sky_vis[i]
			sum = sum + v
			if v < lo then lo = v end
			if v > hi then hi = v end
		end
		return sum / CELL_COUNT, lo, hi
	end

	-- How much of the sky is visible overhead: 1 out in the open, towards
	-- 0 underground ([CAVE_SKY]). **The +Y face rather than the whole
	-- cube**: half the cube looks at the ground wherever the player is
	-- standing, so a whole-cube mean is about a half in broad daylight. The
	-- face is the cone of directions whose largest component is up, which
	-- is where the daylight comes from.
	function self:above()
		local sum = 0
		for i = ABOVE_FIRST, ABOVE_LAST do
			sum = sum + sky_vis[i]
		end
		return sum / (ABOVE_LAST - ABOVE_FIRST + 1)
	end

	-- How lit the brightest air this chamber shows the camera is: 0 where
	-- every direction ends in rock or in unlit air, towards 1 where some
	-- direction ends in air the daylight reached ([UNDERGROUND_LIGHT]: a
	-- cave lit at its far end lights all of itself, and no face can work
	-- that out, since the light arrives round a corner). **The brightest
	-- few cells rather than the brightest one**: a cell's value chases its
	-- own sampling, and a lit far end of a few degrees lands in several.
	function self:chamber()
		-- An insertion sort over eight, against 216 values
		local best = {}
		for i = 1, BEST_CELLS do
			best[i] = 0.0
		end
		for i = 1, CELL_COUNT do
			local v = sky_vis[i]
			if v > best[BEST_CELLS] then
				local j = BEST_CELLS
				while j > 1 and best[j - 1] < v do
					best[j] = best[j - 1]
					j = j - 1
				end
				best[j] = v
			end
		end
		local sum = 0
		for i = 1, BEST_CELLS do
			sum = sum + best[i]
		end
		return sum / BEST_CELLS
	end

	return self
end

local function lum(c)
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
end

-- pbr's moonlight: the render's 4100 K lamp. The parity modes' cold blue
-- moon (0.55, 0.68, 1.0) is Luanti's look, and theirs alone.
M.MOON_COLOR = {r = 1.0, g = 0.86, b = 0.70}

-- **The light terms** ([LC_SKY_SHARED] 2), computing the light and
-- setting nothing. sky is extensions/physical_sky, whichever copy the
-- caller runs (its server's or the bundled one).
-- What a face gets at a sun height under a dome of that hue (sky.dome()):
--   sun, sun_color   the sun's irradiance and colour (PHYS.sun_rgb)
--   moon, moon_color the moon's: the render's, a 4100 K lamp -- the cold
--                    blue is the parity modes' look, and the night probe
--                    read pbr's snow blue against the render's warm
--                    ([NIGHT_LIGHT], 2026-09-20)
--   sky              a face with the whole sky, the dome's hue at its mean
--   ambient          sky plus [DAWN_LIGHT]'s share of the glow
--   bounce, ground, lamp, sun_level (the sun on a level face)
--   glow, glow_tint  the glow on the sky's band (physical_sky's set_dawn_glow)
function M.terms(sky, height, dome)
	local PHYS = sky.PHYS
	local t = {}
	t.sun = PHYS.sun(height)
	local sr, sg, sb = PHYS.sun_rgb(height)
	t.sun_color = {r = sr, g = sg, b = sb}
	t.moon = PHYS.moon_e
	t.moon_color = M.MOON_COLOR
	-- The sky's mean radiance, which the shader multiplies by how much sky
	-- a face sees. What a horizontal face receives over pi: the render's
	-- grass (albedo 0.036) reads 1.50 sunlit at 13:00 and 0.15 in the
	-- shade at 05:45, which leaves the dome at about the zenith's radiance
	-- -- the horizon's band is bright but at a grazing weight. PHYS.dome of
	-- it: the render's snow in an open shadow at 10:00 reads (1.6, 3.0,
	-- 5.3), which off snow's albedo is a dome of 3.2 against a drawn zenith
	-- patch of 4.5 -- Nishita's dome is bright toward the sun and dark
	-- away, and a face sees the mean.
	local mean = PHYS.night_sky +
			(PHYS.sky_zenith * PHYS.dome - PHYS.night_sky) * PHYS.sky(height)
	-- In the drawn sky's own hue, which is what a shadow on snow is lit by:
	-- the render's reads (1.6, 3.0, 5.3), the sky's blue, where a grey
	-- ambient gave a grey shadow
	local l = lum(dome)
	local k = l > 1e-6 and mean / l or 0
	t.sky = {r = dome.r * k, g = dome.g * k, b = dome.b * k}
	-- [DAWN_LIGHT]'s glow: on the sky's band, and a share of it added to
	-- the three ambient terms in its orange -- each of which the shader
	-- gates by the face's sky, so a sealed chamber keeps its dark; never
	-- into the cave floor
	local glow = sky.dawn_glow(height)
	local gc = sky.DAWN_COLOR
	local ga, gs = glow * sky.DAWN_AMBIENT, glow * sky.DUSK_SKY
	t.glow = {r = gs * gc.r, g = gs * gc.g, b = gs * gc.b}
	t.glow_tint = sky.dusk_tint(height)
	t.ambient = {r = t.sky.r + ga * gc.r, g = t.sky.g + ga * gc.g,
		b = t.sky.b + ga * gc.b}
	-- What a face the sky does not reach gets instead: light off the
	-- surroundings, a share of the sky's mean in its hue ([PBR_FIT] term
	-- 2), fitted to the render's cave mouth. simplified: one share for the
	-- whole day; the render's cave at other hours is what would fit it
	-- further.
	t.bounce = {r = t.ambient.r * PHYS.bounce, g = t.ambient.g * PHYS.bounce,
		b = t.ambient.b * PHYS.bounce}
	-- A lamp at full in the sky's units: PHYS.lamp, in the glowstone's own
	-- orange, at a torch's own faces ([TORCH_LIGHT]). simplified: one level
	-- and one colour for every light source; a torch is not a glowstone.
	t.lamp = {r = PHYS.lamp * 1.0, g = PHYS.lamp * 0.6, b = PHYS.lamp * 0.3}
	-- The sun on a level face, over pi
	t.sun_level = t.sun * math.max(height, 0) / math.pi
	-- And the ground as the lower hemisphere sees it: its albedo times what
	-- falls on it, the sky on all of it and a third of the sun, over pi. A
	-- third, not the half that is lit on average: the ground a shaded wall
	-- faces is partly in the same shadow, and the base pass has no shadow
	-- map to say which ([PBR_FIT], contrast_dirt against
	-- contrast_dirt_pit). simplified: one albedo for every ground.
	local s = t.sun_level
	t.ground = {
		r = PHYS.ground.r * (s * sr + t.ambient.r),
		g = PHYS.ground.g * (s * sg + t.ambient.g),
		b = PHYS.ground.b * (s * sb + t.ambient.b)}
	return t
end

-- **An object's light** (a model, the hand, a dropped item, drawn unlit
-- in the frame's units, [OBJECT_LIGHT]): PBRVoxel.glsl's vertex terms for
-- a face with no sun at a sky and a lamp level (0..1), with units
-- {ambient, bounce, lamp, sun} -- M.terms()' ambient, its sky times
-- PHYS.bounce, its lamp, and its sun_level in the sun's colour. The sky
-- share is the nibble times the face's local shade, which the mesher packs
-- beside it and an object has no reading of: taken as the nibble again, an
-- open place's; the bounce where the shaped nibble (the knee at 2..11)
-- says the sky does not reach; a lamp by its falloff over the nibble's
-- distance from a torch's level (M.lamp_curve()).
-- simplified: no ground term and no normal (a side sees half the sky);
-- level 2 is where a normal takes its share.
-- The pbr path decodes its texel (pow 2.2) and an unlit object does not: a
-- mid texel (0.5) is 0.44 of itself decoded, and the object is scaled by
-- that so a mid tone sits level with the world's.
-- simplified: one factor for every texel; the upgrade is an unlit
-- technique that decodes, which level 2's material does anyway.
M.TEXEL_K = 0.44
-- PBRVoxel.glsl's lamp term at a lamp nibble (0..15): its falloff over the
-- nibble's distance from a torch's level. res/light_ramp.png is the same
-- curve over a level 14 light's reach.
function M.lamp_curve(level)
	local d = math.max(math.min(12 - level, 12), 1)
	return (1 / d - 1 / 12) * 12 / 11
end
-- The sun where the sky nibble is full, which in Luanti is direct
-- sunlight, at half: the mean of a face turned to it and one turned away
-- (user: the whole of it made a held pickaxe too bright). no_sun leaves it
-- out, for a lit model that has the sun's light of its own.
-- simplified: no shadow map and no normal; an object in a tree's shadow on
-- open ground is half sunlit. [OBJECT_LIGHT] level 2 is the sun's
-- direction and shadow on it.
function M.object_light(u, sky, lamp, no_sun)
	local t = math.max(0, math.min(1, (sky - 2 / 15) / (9 / 15)))
	local shaped = t * t * (3 - 2 * t)
	local share = sky * sky
	local bounce = (0.15 + sky) * (1 - shaped) * sky
	local lit = M.lamp_curve(15 * lamp)
	local k = M.TEXEL_K
	local a, b, l = u.ambient, u.bounce, u.lamp
	local s = u.sun and sky >= 1 and not no_sun and u.sun or
			{r = 0, g = 0, b = 0}
	local h = 0.5
	return k * (a.r * share + b.r * bounce + l.r * lit + h * s.r),
		k * (a.g * share + b.g * bounce + l.g * lit + h * s.g),
		k * (a.b * share + b.b * bounce + l.b * lit + h * s.b)
end

-- M.terms() onto a target, and the cave's two: the constant floor under
-- the ambient where the chamber the camera is in is dark ([CAVE_AO],
-- PHYS.cave_floor, the same at every hour, which is what
-- [UNDERGROUND_LIGHT]'s invariant needs -- scaled by how unlit the chamber
-- is, it is the whole floor in a sealed place and nothing under an open
-- sky), and the bounce's own floor scaled by how lit the chamber is, so a
-- sealed chamber stops following the hour and a cave lit round a corner
-- keeps its light (gain 1, the user's pick, 2026-09-25). The reading is
-- the camera's rays: no face can work out what arrives round a corner,
-- and the player is taken to be in the chamber they are looking at.
-- sky: physical_sky (or its with() copy), as terms() takes it; chamber:
-- the vis's reading (vis:chamber()); target: plain functions, ambient(r,
-- g, b), bounce, lamp, ground (the same), translucency(k), cave_ambient(r,
-- g, b), chamber_light(f).
function M.apply(target, sky, t, chamber, translucency)
	local PHYS = sky.PHYS
	local a = t.ambient
	target.ambient(a.r, a.g, a.b)
	target.bounce(t.bounce.r, t.bounce.g, t.bounce.b)
	target.lamp(t.lamp.r, t.lamp.g, t.lamp.b)
	target.ground(t.ground.r, t.ground.g, t.ground.b)
	target.translucency(translucency or PHYS.translucency)
	local dark = 1.0 - math.min(1.0, chamber)
	local f = PHYS.cave_floor * dark
	target.cave_ambient(f, f, f)
	target.chamber_light(chamber)
end
-- [TUNNEL_SKY]: what the sky and the fog are drawn as where the camera's
-- chamber reading sees no skylight -- the light the place itself gets, the
-- bounce's floor at the reading (the shader's 0.15 of it) and the cave
-- floor -- so that down a tunnel longer than the view range what shows past
-- the far clip is a dim haze, not the noon sky. Towards the sky's ambient
-- by physical_sky's gate on the reading, so that a place whose chamber sees
-- the sky -- outdoors, a cave mouth, a shaft -- is as before. Returns the
-- colour and the gate (0 sealed, 1 open), for the dome's set_indoors() and
-- set_outside() and the fog.
function M.enclosed(sky, t, chamber)
	local c = math.max(0, math.min(1, chamber))
	local f = sky.PHYS.cave_floor * (1 - c)
	local g = sky.outside(c)
	local function at(bounce, ambient)
		local cave = bounce * 0.15 * c + f
		return cave + (ambient - cave) * g
	end
	return {r = at(t.bounce.r, t.ambient.r), g = at(t.bounce.g, t.ambient.g),
		b = at(t.bounce.b, t.ambient.b)}, g
end

return M
-- vim: set noet ts=4 sw=4:
