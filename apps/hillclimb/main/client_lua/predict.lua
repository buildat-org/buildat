-- Buildat: apps/hillclimb/main/client_lua/predict.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- [CLIENT_WASM] step 5: this client's own car predicted by the module's
-- .wasm (main/wasm/predict.cpp: car.h's step, the server's own), moved by
-- the keys at once instead of a round trip and a packet later, and set
-- to the server's state of it when that differs (a correction). The
-- other cars are drawn as the server sends them (init.lua).
--   local predict = run_script_file("main/predict.lua")()
-- predict.setup(data), predict.state(data): hillclimb:setup and :state;
-- predict.hill(sx, sy, sz): the hill's size, voxels; predict.input(accel,
-- brake, steer, gear): the input's number, a new one when it changed
-- (sent with it, main.cpp on_input); predict.frame(dt): the
-- substeps of the frame, the chunks round the car handed to the module;
-- predict.pose(): the car as hillclimb:car's numbers 1 to 15, or nil
-- before the first state; predict.server_moved(x, y, z): the server's
-- position of the car, for the latency's line.
local voxelworld = require("buildat/module/voxelworld")
local log = buildat.Logger("hillclimb")

local HZ = 240 -- main.cpp's SUBSTEPS_HZ
local CS = 32  -- voxelworld's chunk

-- n as 8 hex digits (no string.format("%x") on a number past 2^31 in
-- every Lua the clients have)
local function hex8(n)
	n = n % 4294967296
	local s = ""
	for _ = 1, 8 do
		s = string.sub("0123456789abcdef", n % 16 + 1, n % 16 + 1) .. s
		n = math.floor(n / 16)
	end
	return s
end
local function bytes(hex)
	return (hex:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end))
end

return function()
	local M = {}
	local seq, last = 0, nil
	-- No module (a platform without wasm yet: the Windows client), or one
	-- that failed: the car as the server sends it, as before the module
	local m, why = buildat.wasm_load("main")
	if m and m:status() == "failed" then
		local _, w = m:status()
		m, why = nil, w
	end
	if m then
		local ok, err = pcall(m.call, m, "hc_init")
		if not ok then
			m, why = nil, err
		end
	end
	if not m then
		log:warning("hillclimb: no prediction, the car as the server sends it: "
				.. tostring(why))
	end
	local setup = nil      -- the last hillclimb:setup's bytes
	local size = nil       -- the hill's, voxels
	local engine = nil
	local synced = false   -- a state taken since the setup
	local now = 0          -- substeps stepped (the module's count)
	local acc = 0
	local starts = {}      -- input number: the substep it took effect at
	local jumps = nil
	local held = false     -- the server's: the brake on, the hill not made
	-- volume: the "x,y,z" it was handed over as (a table keyed by the
	-- volume: luabind's objects have no ==, and the sandbox no rawequal)
	local handed, n_handed = {}, 0
	local chunks_t, chunks_at = 0, nil
	-- Counted over 10 s, and over the run: corrections, those over 1 cm
	-- and their sizes (m), states within the bounds, the largest errors of
	-- position, velocity (m/s) and rotation (rad), states taken whole
	local function fresh(t)
		return {t = t, n = 0, cm = 0, sum = 0, max = 0, kept = 0, dv = 0,
			da = 0, whole = 0, us = 0}
	end
	local st = fresh(0)
	local total = {n = 0, cm = 0, states = 0, t0 = nil}
	-- The latency's line: a key from standing to the car moving 1 cm,
	-- predicted and by the server's state
	local lat = nil

	-- A call into the module that fails (a trap, the meter's stop) ends
	-- the prediction: the car is drawn as the server sends it
	local function guarded(f)
		return function(...)
			if not m then
				return nil
			end
			local ok, r = pcall(f, ...)
			if ok then
				return r
			end
			log:warning("hillclimb: no prediction from here on, the car as the "
					.. "server sends it: " .. tostring(r))
			m = nil
		end
	end

	local apply_setup = guarded(function()
		if not (m and setup and size) then
			return
		end
		m:write(m:call("hc_setup_buf"), setup.bytes)
		m:call("hc_setup", size[1], size[2], size[3])
		local mine = m:call("hc_selftest") % 4294967296
		local _, e = m:status()
		log:info("hillclimb: the car's step from the wasm (" .. tostring(e) ..
				"), self test " .. hex8(mine) .. ", the server's " .. setup.test ..
				(hex8(mine) == setup.test and ": the same" or ": DIFFERENT"))
		engine = e
	end)

	function M.setup(data)
		local test, hex = data:match("^(%x+) (%x+)$")
		if not test then
			return
		end
		setup = {test = test, bytes = bytes(hex)}
		synced = false
		apply_setup()
	end

	function M.hill(sx, sy, sz)
		size = {sx, sy, sz}
		apply_setup()
	end

	function M.input(accel, brake, steer, gear)
		local k = accel .. " " .. brake .. " " .. steer .. " " .. gear .. " " ..
				(held and 1 or 0)
		if k ~= last then
			last = k
			seq = seq + 1
			starts[seq] = now
			starts[seq - 256] = nil
			guarded(function()
				m:call("hc_input", accel, brake, steer, gear, held and 1 or 0)
			end)()
			-- From standing still: timed to the car's first centimetre
			local v = accel == 1 and synced and (not lat or lat.done) and M.pose()
			if v and math.abs(v[15]) < 0.01 then -- the shaft (rev/s): standing
				lat = {t = buildat.get_time_us(), p = {v[1], v[2], v[3]},
					server = nil, pred = nil, done = false}
			end
		end
		return seq
	end

	local function moved(p, x, y, z)
		local dx, dy, dz = x - p[1], y - p[2], z - p[3]
		return dx * dx + dy * dy + dz * dz > 0.08 * 0.08 -- 1 cm, in voxels
	end

	function M.server_moved(x, y, z)
		if lat and not lat.server and moved(lat.p, x, y, z) then
			lat.server = (buildat.get_time_us() - lat.t) / 1000
		end
	end

	-- The chunks round the car, those not handed over or changed since
	local function hand_chunks(x, y, z)
		local cx, cy, cz = math.floor(x / CS), math.floor(y / CS),
				math.floor(z / CS)
		for dz = -1, 1 do for dy = -1, 1 do for dx = -1, 1 do
			local p = buildat.Vector3(cx + dx, cy + dy, cz + dz)
			local node = voxelworld.get_static_node(p)
			local vol = node and voxelworld.get_volume(node)
			local key = p.x .. "," .. p.y .. "," .. p.z
			if vol and handed[vol] ~= key then
				local h = m:handle(vol)
				m:call("hc_chunk", h, p.x, p.y, p.z)
				m:drop(h)
				-- simplified: forgotten all at once past 256, so the volumes
				-- replaced are not kept; the chunks round the car handed again
				if n_handed >= 256 then
					handed, n_handed = {}, 0
				end
				handed[vol] = key
				n_handed = n_handed + 1
			end
		end end end
	end

	M.state = guarded(function(data)
		if not (m and setup) then
			return
		end
		local s, steps, h, j, hex = data:match(
				"^(%d+) (%d+) (%d) (%d+) (%x+)$")
		if not s then
			return
		end
		s, steps, j = tonumber(s), tonumber(steps), tonumber(j)
		local t0 = buildat.get_time_us()
		m:write(m:call("hc_state_buf"), bytes(hex))
		local at = starts[s] and starts[s] + steps
		-- The car put back or reset, or no input of this client's to time
		-- it by: taken as it is
		local force = not synced or j ~= jumps or not at
		jumps = j
		if (h == "1") ~= held then
			held = h == "1"
			last = nil -- the input again, held or not
		end
		local r = m:call("hc_correct", at or 4294967295, force and 1 or 0)
		st.us = st.us + buildat.get_time_us() - t0
		synced = true
		total.states = total.states + 1
		-- Held (the hill being made, observing), the car is not driven, and
		-- the ground may not be here yet: not counted
		if r == 2 or held then
			st.whole = st.whole + (r == 2 and 1 or 0)
			return
		end
		local err = m:call("hc_out", 15)
		st.dv = math.max(st.dv, m:call("hc_out", 16))
		st.da = math.max(st.da, m:call("hc_out", 17))
		st.max = math.max(st.max, err)
		if r == 1 then
			st.n, st.sum, total.n = st.n + 1, st.sum + err, total.n + 1
			if err > 0.01 then
				st.cm, total.cm = st.cm + 1, total.cm + 1
			end
		else
			st.kept = st.kept + 1
		end
	end)

	M.frame = guarded(function(dt)
		if not (m and setup and size) then
			return
		end
		local _, e = m:status()
		if e ~= engine then
			log:info("hillclimb: the car's step from the wasm now " .. tostring(e))
			engine = e
		end
		acc = math.min(acc + dt, 0.25)
		local n = math.floor(acc * HZ)
		acc = acc - n / HZ
		local x, y, z = m:call("hc_out", 0), m:call("hc_out", 1),
				m:call("hc_out", 2)
		local t = buildat.get_time_us()
		local at = math.floor(x / CS) .. "," .. math.floor(y / CS) .. "," ..
				math.floor(z / CS)
		if t - chunks_t > 100000 or at ~= chunks_at then
			chunks_t, chunks_at = t, at
			hand_chunks(x, y, z)
		end
		if n > 0 then
			local t0 = buildat.get_time_us()
			now = m:call("hc_step", n)
			st.us = st.us + buildat.get_time_us() - t0
		end
		if lat and not lat.pred and moved(lat.p, m:call("hc_out", 0),
				m:call("hc_out", 1), m:call("hc_out", 2)) then
			lat.pred = (t - lat.t) / 1000
		end
		if lat and lat.pred and lat.server and not lat.done then
			lat.done = true
			log:info(string.format("hillclimb: a key to 1 cm of the car's motion: "
					.. "%.0f ms predicted, %.0f ms by the server's state (and "
					.. "a packet's blending more as drawn before)", lat.pred,
					lat.server))
		end
		total.t0 = total.t0 or t
		if t - st.t >= 10e6 then
			if st.t > 0 then
				log:info(string.format("hillclimb: prediction (%s): %d "
						.. "corrections in 10 s, %d of them over 1 cm, mean %.2f cm; "
						.. "%d states within the bounds; the largest errors %.2f cm, "
						.. "%.1f cm/s, %.2f degrees; %d taken whole; the steps and "
						.. "corrections %.1f ms a second; %d corrections, %d over 1 "
						.. "cm, in %.0f s", tostring(engine), st.n, st.cm,
						st.n > 0 and st.sum / st.n * 100 or 0, st.kept, st.max * 100,
						st.dv * 100, math.deg(st.da), st.whole, st.us / 10000,
						total.n, total.cm, (t - total.t0) / 1e6))
			end
			st = fresh(t)
		end
	end)

	M.pose = guarded(function()
		if not (m and synced) then
			return nil
		end
		local v = {}
		for i = 0, 14 do
			v[i + 1] = m:call("hc_out", i)
		end
		return v
	end)

	return M
end
