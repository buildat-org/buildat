-- Buildat: builtin/kit/client_lua/merge.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- [KIT_ENT_PERF_2] (kit_plan 4z37zzm) Looks drawn merged, fewer draws: on the
-- web a frame follows its draw calls (Brimstone Stunts at 150 draws ~38 fps,
-- 400 ~31 on an Intel HD). Two kinds, both of the looks module.lua built
-- (n.mesh: each part's triangles in its body's frame and the material it
-- wears, by a key of what makes that material):
--   - **Static scenery**, of itself: a look still WAIT frames (module.lua's
--     still()) that nothing else draws or changes by the frame (no client
--     part on its entity, no text, not hidden, faded, sliding, moving,
--     previewed, carried, on a parallax layer, under a merge root) is baked
--     into its REGION's merged geometry, a geometry a material key, its own
--     body hidden. Anything that changes how it is drawn (module.lua's calm
--     ends: its place, turn, state, show, look; drop_look) takes it out at
--     once, its region baked again that frame, its body shown: a client
--     part's entity is never in one, an edit or a server's move takes it
--     out. Additions wait SETTLE frames, so a join's looks come in one bake.
--   - **Merged units** (a look's merge_parts, show.merge, api.h): the root's
--     look and each entity under it that has no nearer root, each as above
--     but moving, baked in the root's look's frame into one model under it,
--     moving as a whole; units of the same parts in the same places share
--     one (a template's geometry, share_geometry: Urho3D draws them
--     instanced, a draw for them all). A part whose place in the root's frame
--     moves past TOL, or whose look changes, is out (the unit baked again);
--     back in at the next scan (SCAN frames) once it is in step again.
-- Picking goes by entity as ever (module.lua's look_frame: the look's node,
-- placed as ever), so edit mode selects a merged look.
-- "event kit_merged" logs what is merged ("kit: merged: ...").
-- simplified: a region bakes again whole as one of its looks comes or goes
-- (its own triangles kept would make that a copy); glass is never merged (its
-- blending sorts by object); a sphere has no n.mesh (never merged)
return function(K)
local M, P, log = K.M, K.P, K.log
local magic = require("buildat/extension/urho3d")
local replicate = require("buildat/extension/replicate")

local REGION = 32 -- m, a static batch's cell along x and z
local WAIT, SETTLE, SCAN = 30, 10, 30 -- frames
local TOL = 1e-3 -- m (and a quaternion's parts): a unit part's place moved
local MAX_GEOMETRIES = 64 -- set_triangle_geometry's

local S = {regions = {}, units = {}, templates = {}, mats = {}, cand = {},
	frame = 0, bakes = 0, bake_us = 0, scan_gen = -1}

-- A node's world transform, 3x4 row by row
local function mat_of(node)
	local m = node.worldTransform
	return {m.m00, m.m01, m.m02, m.m03, m.m10, m.m11, m.m12, m.m13, m.m20, m.m21,
		m.m22, m.m23}
end
local function mul(A, B)
	local r = {}
	for i = 0, 8, 4 do
		local a0, a1, a2 = A[i + 1], A[i + 2], A[i + 3]
		for j = 1, 4 do
			r[i + j] = a0 * B[j] + a1 * B[4 + j] + a2 * B[8 + j] + (j == 4 and A[i + 4] or 0)
		end
	end
	return r
end
local function inv(A)
	local a, b, c, tx, d, e, f, ty, g, h, i, tz = A[1], A[2], A[3], A[4], A[5], A[6],
			A[7], A[8], A[9], A[10], A[11], A[12]
	local c00, c01, c02 = e * i - f * h, f * g - d * i, d * h - e * g
	local det = a * c00 + b * c01 + c * c02
	if math.abs(det) < 1e-12 then
		return nil
	end
	local r = {c00, c * h - b * i, b * f - c * e, 0, c01, a * i - c * g, c * d - a * f, 0,
		c02, b * g - a * h, a * e - b * d, 0}
	for k = 1, 12 do
		r[k] = r[k] / det
	end
	for k = 0, 8, 4 do
		r[k + 4] = -(r[k + 1] * tx + r[k + 2] * ty + r[k + 3] * tz)
	end
	return r
end

-- src's triangles (set_triangle_geometry's 12 numbers a vertex) through A onto
-- dst: the normals by its cofactors (a scale's inverse), a mirror's winding
-- turned back
local function append(dst, src, A)
	local a, b, c, tx, d, e, f, ty, g, h, i, tz = A[1], A[2], A[3], A[4], A[5], A[6],
			A[7], A[8], A[9], A[10], A[11], A[12]
	local n00, n01, n02 = e * i - f * h, f * g - d * i, d * h - e * g
	local n10, n11, n12 = c * h - b * i, a * i - c * g, b * g - a * h
	local n20, n21, n22 = b * f - c * e, c * d - a * f, a * e - b * d
	local flip = a * n00 + b * n01 + c * n02 < 0
	local sign = flip and -1 or 1
	local o = #dst
	for t = 0, #src - 36, 36 do
		for k = 0, 2 do
			local s = t + (flip and k > 0 and 3 - k or k) * 12
			local x, y, z = src[s + 1], src[s + 2], src[s + 3]
			local nx, ny, nz = src[s + 4], src[s + 5], src[s + 6]
			local wx = n00 * nx + n01 * ny + n02 * nz
			local wy = n10 * nx + n11 * ny + n12 * nz
			local wz = n20 * nx + n21 * ny + n22 * nz
			local l = math.sqrt(wx * wx + wy * wy + wz * wz)
			l = l > 0 and sign / l or 0
			dst[o + 1] = a * x + b * y + c * z + tx
			dst[o + 2] = d * x + e * y + f * z + ty
			dst[o + 3] = g * x + h * y + i * z + tz
			dst[o + 4], dst[o + 5], dst[o + 6] = wx * l, wy * l, wz * l
			for q = 7, 12 do
				dst[o + q] = src[s + q]
			end
			o = o + 12
		end
	end
end

-- The material of a key: a copy of the first part's that had it (the key says
-- all that made it)
local function material(key, mat)
	local m = S.mats[key]
	if not m then
		m = mat:Clone()
		S.mats[key] = m
	end
	return m
end

-- What a part list bakes into: lists and materials by key, in key order
local function bake(members)
	local by, keys = {}, {}
	for _, it in ipairs(members) do
		for _, p in ipairs(it.n.mesh) do
			local g = by[p.key]
			if not g then
				g = {list = {}, mat = p.mat}
				by[p.key] = g
				keys[#keys + 1] = p.key
			end
			append(g.list, p.list, it.A)
		end
	end
	table.sort(keys)
	local lists, mats = {}, {}
	for k, key in ipairs(keys) do
		lists[k], mats[k] = by[key].list, material(key, by[key].mat)
	end
	return lists, mats
end

local function reach_of(c)
	local d = M.look_reach
	if not d then
		return 0
	end
	local bb = c.worldBoundingBox
	return d + (bb.max - bb.min):Length() / 2
end

-- Geometry lists and their materials onto node's CustomGeometry
local function put(node, lists, mats)
	buildat.set_triangle_geometry(node, lists)
	local cg = node:GetComponent("CustomGeometry")
	for k, m in ipairs(mats) do
		cg:SetMaterial(k - 1, m)
	end
	cg.castShadows = true
	cg.drawDistance = reach_of(cg)
	return cg
end

local function shown(n)
	local look = type(n.show) == "table" and type(n.show.look) == "table" and n.show.look
	return n.box and n.box.color ~= "none" and not (look and look.hidden) and
			not n.see_through
end

-- Its own body drawn again, as module.lua has it (its edges, children of
-- the body, too: a node's enabled is not its children's)
local function unhide(n)
	n.body:SetDeepEnabled(true)
	n.body.enabled = shown(n)
end

-- Whether its look as drawn now can be baked at all (static or in a unit)
local function bakeable(n)
	local show = type(n.show) == "table" and n.show or {}
	local look = type(show.look) == "table" and show.look
	if not (n.look and n.mesh and n.body and look and shown(n)) or
			look.material == "glass" or n.text or n.ghost or n.vanish or n.slide_to or
			n.wear_wanted or n.attach_to or n.par_copies or n.far_look or
			(type(show.client) == "table" and #show.client > 0) then
		return false
	end
	return M.parallax_layer(n.id, n) == nil
end

-- The nearest merge root up from n (n itself one), or nil; memo (one
-- scan's) keeps what each node on the way found (false: none)
local function root_of(n, memo)
	local way, r = {}, nil
	for _ = 1, 16 do
		local m = memo and memo[n]
		if m ~= nil then
			r = m or nil
			break
		end
		way[#way + 1] = n
		if type(n.show) == "table" and n.show.merge == true and n.look then
			r = n
			break
		end
		local pid = K.parent_id(n)
		n = pid ~= 0 and P.nodes[pid]
		if not n then
			break
		end
	end
	if memo then
		for _, w in ipairs(way) do
			memo[w] = r or false
		end
	end
	return r
end

---- Static regions

local function region_out(n)
	local r = n.mg
	r.members[n] = nil
	r.count = r.count - 1
	r.now = true
	n.mg, n.still_at = nil, nil
	if n.mg_in and n.body then
		unhide(n)
	end
	n.mg_in = nil
end

local function region_bake(r)
	local members = {}
	for n in pairs(r.members) do
		members[#members + 1] = {n = n, A = n.mg_A}
	end
	local lists, mats = bake(members)
	local k = 0
	for first = 1, #lists, MAX_GEOMETRIES do
		k = k + 1
		local node = r.nodes[k]
		if not node then
			node = replicate.main_scene:CreateChild("kit_merged")
			r.nodes[k] = node
		end
		local l, m = {}, {}
		for j = first, math.min(#lists, first + MAX_GEOMETRIES - 1) do
			l[#l + 1], m[#m + 1] = lists[j], mats[j]
		end
		put(node, l, m)
	end
	while #r.nodes > k do
		r.nodes[#r.nodes]:Remove()
		r.nodes[#r.nodes] = nil
	end
	for n in pairs(r.members) do
		if not n.mg_in then
			n.mg_in = true
			n.body:SetDeepEnabled(false)
		end
	end
	r.keys = #lists
end

---- Units

-- m's place and turn in r's entity frame: 7 numbers (its turn's w >= 0),
-- or nil
local function rel7(m, r)
	local a, q, ra, rq = m.at, m.at_q, r.at, r.at_q
	if not (a and q and ra and rq) then
		return nil
	end
	-- conj(rq) * (a - ra), conj(rq) * q
	local w, x, y, z = rq.w, -rq.x, -rq.y, -rq.z
	local vx, vy, vz = a.x - ra.x, a.y - ra.y, a.z - ra.z
	local tx, ty, tz = 2 * (y * vz - z * vy), 2 * (z * vx - x * vz), 2 * (x * vy - y * vx)
	local qw = w * q.w - x * q.x - y * q.y - z * q.z
	local qx = w * q.x + x * q.w + y * q.z - z * q.y
	local qy = w * q.y - x * q.z + y * q.w + z * q.x
	local qz = w * q.z + x * q.y - y * q.x + z * q.w
	if qw < 0 then
		qw, qx, qy, qz = -qw, -qx, -qy, -qz
	end
	return vx + w * tx + (y * tz - z * ty), vy + w * ty + (z * tx - x * tz),
			vz + w * tz + (x * ty - y * tx), qw, qx, qy, qz
end
local function relpose(m, r)
	local t = {rel7(m, r)}
	return t[1] and t or nil
end
-- Whether m is off rel in r's frame by more than TOL (no table: each member
-- each frame)
local function moved_from(m, r, rel)
	local px, py, pz, qw, qx, qy, qz = rel7(m, r)
	if not (px and rel) then
		return true
	end
	local abs = math.abs
	return abs(px - rel[1]) > TOL or abs(py - rel[2]) > TOL or abs(pz - rel[3]) > TOL or
			abs(qw - rel[4]) > TOL or abs(qx - rel[5]) > TOL or abs(qy - rel[6]) > TOL or
			abs(qz - rel[7]) > TOL
end

local function template_drop(sig)
	local t = sig and S.templates[sig]
	if t then
		t.refs = t.refs - 1
		if t.refs <= 0 then
			t.node:Remove()
			S.templates[sig] = nil
		end
	end
end

local function unit_free(u)
	for m in pairs(u.members) do
		if m.mg == u then
			m.mg = nil
			if m.mg_in and m.body then
				unhide(m)
			end
			m.mg_in = nil
		end
	end
	u.members = {}
	template_drop(u.sig)
	u.sig = nil
	if u.node and u.look == u.root.look then
		u.node:Remove()
	end
	u.node = nil
end

-- The unit's members baked (a template's, shared) under its root's look
local function unit_bake(u)
	local descs, list = {}, {}
	for m, rec in pairs(u.members) do
		local p = rec.rel
		local f = math.floor
		descs[#descs + 1] = string.format("%s|%s|%d,%d,%d,%d,%d,%d,%d",
				tostring(m.show_raw), tostring(m.on), f(p[1] * 1e3 + 0.5), f(p[2] * 1e3 + 0.5),
				f(p[3] * 1e3 + 0.5), f(p[4] * 1e3 + 0.5), f(p[5] * 1e3 + 0.5), f(p[6] * 1e3 + 0.5),
				f(p[7] * 1e3 + 0.5))
		list[#list + 1] = m
	end
	table.sort(descs)
	local sig = table.concat(descs, ";")
	if sig == u.sig then
		return
	end
	template_drop(u.sig)
	u.sig = nil
	if #list == 0 then
		if u.node then
			u.node:Remove()
			u.node = nil
		end
		return
	end
	local t = S.templates[sig]
	if not t then
		local Rinv = inv(mat_of(u.root.look))
		if not Rinv then
			return
		end
		local members = {}
		for _, m in ipairs(list) do
			members[#members + 1] = {n = m, A = mul(Rinv, mat_of(m.body))}
		end
		local lists, mats = bake(members)
		if #lists > MAX_GEOMETRIES then
			return
		end
		local node = replicate.main_scene:CreateChild("kit_merge_template")
		node.enabled = false
		put(node, lists, mats)
		t = {node = node, refs = 0, keys = #lists}
		S.templates[sig] = t
		S.bakes = S.bakes + 1
	end
	t.refs = t.refs + 1
	u.sig = sig
	if not u.node then
		u.node = u.root.look:CreateChild("kit_merged")
		u.look = u.root.look
	end
	buildat.share_geometry(t.node, u.node)
	local sm = u.node:GetComponent("StaticModel")
	if sm then
		sm.drawDistance = reach_of(sm)
	end
	for m in pairs(u.members) do
		if not m.mg_in then
			m.mg_in = true
			m.body:SetDeepEnabled(false)
		end
	end
end

-- The units: each root's members found again (each SCAN frames), each
-- frame a member gone out of step taken out
local function units_frame(scan)
	local want = {}
	if scan then
		local memo = {}
		for _, n in pairs(P.nodes) do
			local r = n.look and root_of(n, memo)
			if r then
				local w = want[r]
				if not w then
					w = {}
					want[r] = w
				end
				if bakeable(n) then
					w[n] = relpose(n, r)
				end
			end
		end
		for r, u in pairs(S.units) do
			if not want[r] or not P.nodes[r.id] then
				unit_free(u)
				S.units[r] = nil
			end
		end
	end
	for r, u in pairs(S.units) do
		local dirty = false
		if u.node and u.look ~= r.look then
			-- (its root's look built again: the merged node went with it)
			u.node = nil
			unit_free(u)
			dirty = true
		end
		-- (all of it still this frame: nothing of it changed)
		local still = r.still
		if still then
			for m in pairs(u.members) do
				if not m.still then
					still = false
					break
				end
			end
		end
		for m, rec in pairs(still and {} or u.members) do
			if m.look ~= rec.look or m.box ~= rec.box or not shown(m) or m.ghost or
					m.text or m.vanish or moved_from(m, r, rec.rel) then
				u.members[m] = nil
				m.mg = nil
				if m.mg_in and m.body then
					unhide(m)
				end
				m.mg_in = nil
				dirty = true
			end
		end
		if dirty then
			unit_bake(u)
		end
	end
	if not scan then
		return
	end
	for r, w in pairs(want) do
		local u = S.units[r]
		if not u then
			u = {root = r, members = {}}
			S.units[r] = u
		end
		local dirty = false
		for m, rel in pairs(w) do
			-- (one baked static before its root's merge_parts came on)
			if m.mg and m.mg.static then
				region_out(m)
			end
			if not u.members[m] and m.mg == nil and rel then
				-- (in step since the last scan: its place then the same)
				local was = m.mg_rel
				m.mg_rel = rel
				if was and not moved_from(m, r, was) then
					u.members[m] = {look = m.look, box = m.box, rel = rel}
					m.mg = u
					dirty = true
				end
			end
		end
		if dirty then
			unit_bake(u)
		end
	end
end

---- module.lua's calls

-- Each node each frame, still or not (update_play's first pass)
function M.merge_seen(n, still)
	if not still or S.off then
		n.still_at = nil
		return
	end
	if n.mg or not n.mesh then
		return
	end
	n.still_at = n.still_at or S.frame
	if S.frame - n.still_at >= WAIT and (n.mg_no ~= n.box or n.mg_gen ~= P.nodes_gen) then
		S.cand[#S.cand + 1] = n
	end
end

-- A busy node, as update_play is done with it: calm, nothing of how it is
-- drawn changed this frame
function M.merge_busy(n, calm)
	local r = n.mg
	if r and r.static and (not calm or not bakeable(n) or n.rest or
			P.preview[n.id] or P.pose[n.id]) then
		region_out(n)
	end
end

-- Its look dropped (module.lua's drop_look)
function M.merge_drop(n)
	-- (a unit's root: the unit with it)
	local u = S.units[n]
	if u then
		unit_free(u)
		S.units[n] = nil
	end
	local g = n.mg
	if not g then
		return
	end
	if g.static then
		region_out(n)
	else
		g.members[n] = nil
		n.mg, n.mg_in = nil, nil
		unit_bake(g)
	end
	n.mg_rel = nil
end

-- After update_play's pass: the candidates in, the regions and units baked
function M.merge_flush()
	if S.off then
		return
	end
	S.frame = S.frame + 1
	local t0 = buildat.get_time_us()
	for _, n in ipairs(S.cand) do
		if n.look and not n.mg and bakeable(n) and not n.rest and not P.preview[n.id] and
				not P.pose[n.id] and not root_of(n) then
			local A = mat_of(n.body)
			local key = math.floor(A[4] / REGION) .. "," .. math.floor(A[12] / REGION)
			local r = S.regions[key]
			if not r then
				r = {static = true, key = key, members = {}, count = 0, nodes = {}}
				S.regions[key] = r
			end
			r.members[n] = true
			r.count = r.count + 1
			r.added = S.frame
			n.mg, n.mg_A = r, A
		else
			n.mg_no, n.mg_gen = n.box, P.nodes_gen
		end
	end
	S.cand = {}
	for key, r in pairs(S.regions) do
		if r.now or (r.added and S.frame - r.added >= SETTLE) then
			r.now, r.added = nil, nil
			region_bake(r)
			S.bakes = S.bakes + 1
			if r.count == 0 then
				S.regions[key] = nil
			end
		end
	end
	units_frame(S.frame % SCAN == 0)
	S.bake_us = S.bake_us + buildat.get_time_us() - t0
end

-- The look reach changed (module.lua's set_look_reach): the merged ones' too
function M.merge_reach()
	for _, r in pairs(S.regions) do
		for _, node in ipairs(r.nodes) do
			local cg = node:GetComponent("CustomGeometry")
			cg.drawDistance = reach_of(cg)
		end
	end
	for _, u in pairs(S.units) do
		local sm = u.node and u.node:GetComponent("StaticModel")
		if sm then
			sm.drawDistance = reach_of(sm)
		end
	end
end

-- "event kit_merged off": every look drawn on its own from then on, "on"
-- merged again (a check's and a measure's before and after); "region <m>"
-- the static cell's size from then on (a measure's; off and on after)
magic.SubscribeToEvent("command_seq:kit_merged", function(_, data)
	local arg = data:GetString("Param")
	if arg == "off" and not S.off then
		for _, r in pairs(S.regions) do
			for n in pairs(r.members) do
				region_out(n)
			end
			region_bake(r)
		end
		for _, u in pairs(S.units) do
			unit_free(u)
		end
		S.regions, S.units, S.cand, S.off = {}, {}, {}, true
	end
	if arg == "on" then
		S.off = nil
	end
	local rg = tonumber(arg:match("^region (%S+)$"))
	if rg and rg >= 1 then
		REGION = rg
	end
	if arg ~= "" then
		return
	end
	local regions, nodes, static, units, members, keys = 0, 0, 0, 0, 0, 0
	for _, r in pairs(S.regions) do
		regions, nodes, static = regions + 1, nodes + #r.nodes, static + r.count
		keys = keys + (r.keys or 0)
	end
	for _, u in pairs(S.units) do
		units = units + (u.sig and 1 or 0)
		for _ in pairs(u.members) do
			members = members + 1
		end
	end
	local templates, mats = 0, 0
	for _ in pairs(S.templates) do
		templates = templates + 1
	end
	for _ in pairs(S.mats) do
		mats = mats + 1
	end
	log:info(string.format("kit: merged: %d static looks in %d regions (%d geometries, %d " ..
			"nodes), %d units of %d looks on %d models; %d bakes, %.2f ms a frame; %d " ..
			"draws the last frame; %d materials, regions of %g m", static, regions, keys, nodes,
			units, members, templates,
			S.bakes, S.bake_us / 1000 / math.max(1, S.frame), magic.renderer.numBatches,
			mats, REGION))
end)
end
