-- Buildat: builtin/kit/client_lua/prefabs.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- [KIT_PREFAB_ROOT] The editor's side of a placed prefab: its root
-- (kit/prefab_copy; a row's "prefab": {of, version, voxels}) in the inspector,
-- a member's own parameters, the palette's menu on a prefab, and the dialog that
-- stamps the prefab's voxels. editor.lua runs this file and puts it at NT.pf.
--   - The root's inspector: which prefab, Save to prefab (no name: that one's new
--     version, of what is under it, with its box of voxels if it has one or the
--     Box tool has one; the prefab's owner alone), Detach, Refresh voxels.
--   - A member's parameter set on it is listed under its form with a Reset to the
--     prefab's value.
--   - The prefab's box is drawn while its root is selected.
--   - A single root with voxels moved by this builder (a drag, typed, a key, a
--     turn), once the server has it, and Refresh voxels: one dialog. As a child
--     of what moved, or with others in a selection, the voxels just stay. An Undo
--     is no move. simplified: the dialog is no modal; answered after more edits,
--     its stamp is its own undo.
--   - [KIT_PREFAB_BENCH] The palette menu's Edit, on one's own prefab: the bar's
--     "Editing prefab X: Save, Close" in a temporary scene (kit.cpp's
--     prefab_bench()), the view at the copy, the box in the Box tool's handles.
--     Save is the root's Save to prefab with that box. Close asks only if an edit
--     was sent or the box moved since the last Save.
--   - [KIT_FREE_PREFAB] A free copy (the root's mode; the menu's Place free): no
--     Refresh or move's dialog, its box turned with it and a part of what a press
--     picks, its object following a drag's preview. The switch of mode asks once
--     what becomes of a stamped copy's voxels.
return function(A)
local K, S, W, NT = A.K, A.S, A.W, A.NT
local E, P = K.E, K.P
local magic = require("buildat/extension/urho3d")
local log = K.log
local send, window, find, drop, drawn_at = A.send, A.window, A.find, A.drop,
		A.drawn_at
local M, BX = K.M, A.BX
local row, text, label, button, edit = K.row, K.text, K.label, K.button, K.edit
local DIM = K.DIM

local PF = {}
NT.pf = PF

-- What the server says of a prefab, nil if there is none of that name
local function info_of(name)
	return E.state and E.state.prefabs_info and E.state.prefabs_info[name]
end

local function dialog()
	drop("dialog")
	local w = window(magic.HA_CENTER, magic.VA_CENTER, 0, 0)
	W.dialog = w
	w.priority = 10
	return w
end

local function close()
	drop("dialog")
end

-- [KIT_FREE_PREFAB] This row is a free copy's root
local function is_free(e)
	if type(e.prefab) ~= "table" then
		return false
	end
	for _, c in ipairs(e.components or {}) do
		if c.type == "kit/prefab_copy" then
			return type(c.params) == "table" and c.params.mode == "free"
		end
	end
	return false
end

-- Its box's corner in its frame, a cell's middle its whole coordinates: lo, hi
local function free_box(info)
	return {info.at[1] - 0.5, info.at[2] - 0.5, info.at[3] - 0.5},
		{info.at[1] + info.size[1] - 0.5, info.at[2] + info.size[2] - 0.5,
			info.at[3] + info.size[3] - 0.5}
end

-- A free copy's place and turn as drawn, its info, its yaw; nil when it is not
-- one
local function free_place(e)
	local info = e.pos and is_free(e) and info_of(e.prefab.of)
	if not (info and info.size) then
		return nil
	end
	local pv = P.preview[e.id]
	return drawn_at(e), NT.drawn_turn(e), info, pv and pv[4] or e.yaw or 0
end
PF.is_free = is_free

-- [editor.lua's pick] How far along the ray (arrays) a free copy's box is
function PF.pick_t(e, o, v)
	local c, q, info = free_place(e)
	if not c then
		return nil
	end
	local inv = magic.Quaternion(q.w, -q.x, -q.y, -q.z)
	local lp = inv * (magic.Vector3(o[1], o[2], o[3]) - c)
	local ld = inv * magic.Vector3(v[1], v[2], v[3])
	local lo_, hi_ = free_box(info)
	local p = {lp.x, lp.y, lp.z}
	local d = {ld.x, ld.y, ld.z}
	local t0, t1 = 0, math.huge
	for i = 1, 3 do
		if math.abs(d[i]) < 1e-9 then
			if p[i] < lo_[i] or p[i] > hi_[i] then
				return nil
			end
		else
			local q0, q1 = (lo_[i] - p[i]) / d[i], (hi_[i] - p[i]) / d[i]
			if q0 > q1 then
				q0, q1 = q1, q0
			end
			t0, t1 = math.max(t0, q0), math.min(t1, q1)
		end
	end
	return t0 <= t1 and t0 or nil
end

-- [editor_input.lua's knob] Past a free copy's box; 0 for anything else
function PF.knob_radius(e)
	local c, _, info = free_place(e)
	if not c then
		return 0
	end
	local lo_, hi_ = free_box(info)
	local r = 0
	for _, x in ipairs({lo_[1], hi_[1]}) do
		for _, y in ipairs({lo_[2], hi_[2]}) do
			for _, z in ipairs({lo_[3], hi_[3]}) do
				r = math.max(r, math.sqrt(x * x + y * y + z * z))
			end
		end
	end
	return r + 0.6
end

-- [KIT_PREFAB_ROOT] The root's lines in the inspector
function PF.section(w, e)
	local of = tostring(e.prefab.of)
	local info = info_of(of)
	local free = is_free(e)
	text(w, "Copy of prefab " .. of .. " v" .. tostring(e.prefab.version) ..
			(info and "" or " (deleted)"), DIM)
	if free then
		text(w, "A free object: its copies change with the prefab", DIM)
	end
	if info and info.version ~= e.prefab.version then
		text(w, "Prefab is at v" .. tostring(info.version) ..
				": follows at its next save", DIM)
	end
	if info and not free and info.voxels and (e.prefab.voxels or 0) < info.voxels then
		local behind = "voxels v" .. tostring(e.prefab.voxels or 0) .. ", prefab v" ..
				tostring(info.voxels)
		text(w, behind)
		if PF.behind_logged ~= behind then
			PF.behind_logged = behind
			log:info("kit editor: " .. behind)
		end
	end
	-- A deleted one's author is not known here: the server refuses another's
	if not info or info.own then
		button(w, "Save to prefab", function()
			send({op = "save_prefab", root = e.id, box = A.vbox()})
			log:info("kit editor: save to prefab " .. of .. " from " .. e.id)
		end)
	end
	button(w, "Detach", function()
		send({op = "prefab_detach", id = e.id})
		log:info("kit editor: detach " .. e.id)
	end)
	if info and info.size and not free then
		button(w, "Refresh voxels", function()
			log:info("kit editor: refresh voxels of " .. e.id)
			PF.stamp_dialog(e.id)
		end)
	end
	-- The inspector's fit cuts a last row of buttons short by a few pixels
	text(w, " ", DIM)
end

-- A copy's member: each parameter set on it, and back to the prefab's
function PF.overrides(w, e, ci)
	local c = e.components[ci]
	local g = type(e.built) == "table" and find(e.built.by)
	if not (g and type(g.prefab) == "table" and c.overrides) then
		return
	end
	for _, k in ipairs(c.overrides) do
		local r = row(w)
		label(r, "* " .. k .. ": its own")
		button(r, "Reset " .. k, function()
			send({op = "prefab_reset", id = e.id, comp = ci - 1, param = k})
			log:info("kit editor: reset " .. e.id .. "'s " .. k)
		end)
	end
end

-- The dialog stamping the prefab at the root: from {x, y, z, yaw}, where it was
-- moved from (a move); nil a Refresh
function PF.stamp_dialog(id, from)
	local e = find(id)
	if not e then
		return
	end
	local w = dialog()
	text(w, (from and "Moved a copy of " or "Refresh the voxels of ") ..
			tostring(e.prefab.of))
	text(w, "Clearing empties all cells of the box, terrain too.", DIM)
	local function stamp(clear)
		return function()
			close()
			send({op = "stamp", id = id, clear = clear, from = clear and from or nil,
				merge = from ~= nil})
			log:info("kit editor: stamp " .. id .. (clear and ", clearing" or ""))
		end
	end
	button(w, "Clear the old box, then stamp", stamp(true))
	button(w, "Stamp without clearing", stamp(false))
	button(w, from and "Leave the voxels" or "Cancel", function()
		close()
		log:info("kit editor: no stamp of " .. id)
	end)
	log:info("kit editor: the stamp dialog of " .. id ..
			(from and " after a move" or ""))
end

-- [editor.lua's send] An edit going out: a single root with voxels moving is
-- remembered as it was, until its row comes moved or the edit is refused
K.prefab_moving = function(j)
	if j.op == "set" then
		-- [KIT_FREE_PREFAB] the switch of mode's question, once the row has it
		if j.param == "mode" and type((find(j.id) or {}).prefab) == "table" then
			PF.mode_pending = {id = j.id, to = j.value}
		end
		return
	end
	if not j.id or not j.pos then
		return
	end
	local e, made = find(j.id)
	if not e or made or type(e.prefab) ~= "table" or not e.pos or is_free(e) then
		return
	end
	local info = info_of(e.prefab.of)
	if not (info and info.size) or (PF.pending and PF.pending.id == j.id) then
		return
	end
	PF.pending = {id = j.id, pitch = e.pitch or 0, roll = e.roll or 0,
		from = {e.pos[1], e.pos[2], e.pos[3], e.yaw or 0}}
end

-- [KIT_PREFAB_BENCH] Into the bench: the box, the view on it; what the builder
-- had, for the way out
local function box_key()
	local b = A.vbox()
	return b and table.concat(b, ",") or ""
end

local function bench_enter()
	local ses = E.session
	PF.bench_was = PF.bench_was or {pos = S.pos, yaw = S.yaw, pitch = S.pitch,
		view = S.view, tool = S.tool}
	local lo, hi = {0, 0, 0}, {0, 1, 0}
	S.sel, S.primary, S.placing = {}, nil, nil
	if type(ses.box) == "table" then
		lo = {ses.box[1], ses.box[2], ses.box[3]}
		hi = {ses.box[4], ses.box[5], ses.box[6]}
		M.set_tool("box")
		BX.set_box(lo, hi, "the prefab's")
	else
		M.set_tool(nil)
	end
	local d = math.max(hi[1] - lo[1], hi[2] - lo[2], hi[3] - lo[3]) + 7
	S.pos = {x = (lo[1] + hi[1]) / 2 + 0.5, y = (lo[2] + hi[2]) / 2 + 0.5 + d * 0.7,
		z = (lo[3] + hi[3]) / 2 + 0.5 - d}
	S.yaw, S.pitch = 0, math.deg(math.atan2(d * 0.7, d))
	M.set_view("3d")
	PF.bench = {id = ses.id, prefab = ses.prefab, root = ses.root, box = box_key(),
		version = (info_of(ses.prefab) or {}).version, dirty = false}
	log:info("kit editor: editing the prefab " .. tostring(ses.prefab) ..
			" in session " .. tostring(ses.id))
end

local function bench_leave()
	local b = PF.bench_was
	PF.bench, PF.bench_was = nil, nil
	S.sel, S.primary, S.placing = {}, nil, nil
	M.set_tool(b.tool)
	S.pos, S.yaw, S.pitch = b.pos, b.yaw, b.pitch
	M.set_view(b.view)
	log:info("kit editor: the prefab's scene closed")
end

-- The state's say on the bench: in, out, or a Save come back
local function bench_state()
	local q = PF.bench
	if (E.session or {}).kind == "bench" then
		if not q or q.id ~= E.session.id then
			bench_enter()
			q = PF.bench
		end
		if E.session.ready and not q.ready then
			q.ready = true
			log:info("kit editor: the prefab's voxels are in")
		end
		local v = (info_of(q.prefab) or {}).version
		if v ~= q.version then
			q.version, q.dirty, q.box = v, false, box_key()
		end
	elseif q then
		bench_leave()
	end
end

function PF.bench_save()
	local q = PF.bench
	if q then
		send({op = "save_prefab", root = q.root, box = A.vbox()})
		log:info("kit editor: save the prefab " .. tostring(q.prefab))
	end
end

function PF.bench_close()
	local q = PF.bench
	local function go()
		close()
		send({op = "leave_draft"})
		log:info("kit editor: close the prefab's scene")
	end
	if not q or not (q.dirty or q.box ~= box_key()) then
		return go()
	end
	local w = dialog()
	text(w, "Close without saving " .. tostring(q.prefab) .. "?")
	text(w, "What was changed since the last Save is dropped, no undo.", DIM)
	local br = row(w)
	button(br, "Close it", go)
	button(br, "Keep editing", close)
	log:info("kit editor: close unsaved?")
end

-- [editor.lua's send] What goes out and changes the bench's scene
local READS = {focus = true, voxel_info = true, mode = true, edited = true,
	save_prefab = true, leave_draft = true, sessions = true, copy = true}
K.prefab_bench_sent = function(j)
	if PF.bench and not READS[j.op] then
		PF.bench.dirty = true
	end
end

-- [KIT_FREE_PREFAB] A switch of mode, its row come: to free, the voxels it had
-- stamped are the builder's to clear; to stamped, a stamp if the turn allows one.
-- simplified: not modal, and an Undo of the switch does not ask again
local function mode_switched()
	local q = PF.mode_pending
	local e = q and find(q.id)
	if not q or not e or (q.to == "free") ~= is_free(e) then
		return
	end
	PF.mode_pending = nil
	local info = info_of(e.prefab.of)
	if not (info and info.size) then
		return
	end
	if (e.yaw or 0) % 90 ~= 0 or (e.pitch or 0) ~= 0 or (e.roll or 0) ~= 0 then
		E.status = q.to == "free" and "The stamp's voxels stay: clear them by hand"
				or "No stamp at this turn: turn it by 90s, then Refresh voxels"
		log:info("kit editor: " .. E.status)
	elseif q.to ~= "free" then
		PF.stamp_dialog(q.id)
	else
		local w = dialog()
		text(w, "Now a free object: the voxels stamped for it are still there")
		text(w, "Clearing empties all cells of the box, terrain too.", DIM)
		button(w, "Clear the box", function()
			close()
			send({op = "stamp", id = q.id, only_clear = true, merge = true})
			log:info("kit editor: clear the stamp of " .. q.id)
		end)
		button(w, "Leave the voxels", function()
			close()
			log:info("kit editor: no clearing of " .. q.id)
		end)
		log:info("kit editor: the free dialog of " .. q.id)
	end
end

-- A new state: the move's dialog, once the row has moved
function PF.state()
	bench_state()
	mode_switched()
	local q = PF.pending
	if not q then
		return
	end
	local e = find(q.id)
	if not e then
		PF.pending = nil
		return
	end
	local f = q.from
	if e.pos[1] == f[1] and e.pos[2] == f[2] and e.pos[3] == f[3] and
			(e.yaw or 0) == f[4] and (e.pitch or 0) == q.pitch and
			(e.roll or 0) == q.roll then
		return
	end
	PF.pending = nil
	if (e.yaw or 0) % 90 ~= 0 or (e.pitch or 0) ~= 0 or (e.roll or 0) ~= 0 then
		E.status = string.format("The voxels stay: turned %g, and a stamp takes "
				.. "multiples of 90", e.yaw)
		log:info("kit editor: " .. E.status)
		return
	end
	PF.stamp_dialog(q.id, f)
end

function PF.refused()
	PF.pending = nil
	PF.mode_pending = nil
end

-- [KIT_FREE_PREFAB] The objects of the copies in a drag's preview go with it, and
-- back to their rows after it (a drag let go has its row by then; the server's
-- node comes too)
local preview_held = {}
local function preview_objects()
	local nodes = E.state and E.state.free_objects
	local scene = require("buildat/extension/replicate").main_scene
	if not (nodes and scene) then
		return
	end
	for id, node in pairs(nodes) do
		local e = find(tonumber(id))
		local c, q, info
		if e then
			c, q, info = free_place(e)
		end
		local held = e and P.preview[e.id]
		local n = c and (held or preview_held[id]) and scene:GetNode(node)
		if n then
			local lo_ = free_box(info)
			n.position = c + q * magic.Vector3(lo_[1], lo_[2], lo_[3])
			n.rotation = q
		end
		preview_held[id] = held and true or nil
	end
end

-- A box from lo_ to hi_ ({x, y, z}), in the frame at c turned by q
function PF.draw_box(dbg, c, q, lo_, hi_, col)
	local function at(i)
		local p = i % 2 == 1 and hi_[1] or lo_[1]
		local r = i % 4 >= 2 and hi_[2] or lo_[2]
		local t = i >= 4 and hi_[3] or lo_[3]
		return c + q * magic.Vector3(p, r, t)
	end
	for _, l in ipairs({{0, 1}, {2, 3}, {4, 5}, {6, 7}, {0, 2}, {1, 3}, {4, 6}, {5, 7},
			{0, 4}, {1, 5}, {2, 6}, {3, 7}}) do
		dbg:AddLine(at(l[1]), at(l[2]), col, false)
	end
end

-- A free copy's box, turned with it
local function draw_free(dbg, id, e)
	local c, q, info, yaw = free_place(e)
	local lo_, hi_ = free_box(info)
	PF.draw_box(dbg, c, q, lo_, hi_, magic.Color(0.3, 0.9, 0.9))
	local line = string.format("%d %g,%g,%g yaw %g", id, c.x, c.y, c.z, yaw)
	if PF.box_logged ~= line then
		PF.box_logged = line
		log:info("kit editor: the box of the free copy " .. line)
	end
end

-- The selected roots' boxes, a cell's middle its whole coordinates
function PF.draw(dbg)
	preview_objects()
	for id in pairs(S.sel) do
		local e, made = find(id)
		local info = e and not made and type(e.prefab) == "table" and e.pos and
				info_of(e.prefab.of)
		if info and info.size and is_free(e) then
			draw_free(dbg, id, e)
		elseif info and info.size then
			local c = drawn_at(e)
			local pv = P.preview[id]
			local base = {math.floor(c.x + 0.5), math.floor(c.y + 0.5),
				math.floor(c.z + 0.5)}
			local x0, z0 = info.at[1], info.at[3]
			local x1, z1 = x0 + info.size[1] - 1, z0 + info.size[3] - 1
			for _ = 1, math.floor(((pv and pv[4] or e.yaw or 0)) / 90 + 0.5) % 4 do
				x0, z0, x1, z1 = z0, -x0, z1, -x1
			end
			local lo = {base[1] + math.min(x0, x1), base[2] + info.at[2],
				base[3] + math.min(z0, z1)}
			local hi = {base[1] + math.max(x0, x1),
				base[2] + info.at[2] + info.size[2] - 1, base[3] + math.max(z0, z1)}
			dbg:AddBoundingBox(magic.BoundingBox(
					magic.Vector3(lo[1] - 0.5, lo[2] - 0.5, lo[3] - 0.5),
					magic.Vector3(hi[1] + 0.5, hi[2] + 0.5, hi[3] + 0.5)),
					magic.Color(0.3, 0.9, 0.9), false)
			local line = id .. " " .. table.concat(lo, ",") .. " " ..
					table.concat(hi, ",")
			if PF.box_logged ~= line then
				PF.box_logged = line
				log:info("kit editor: the box of the copy " .. line)
			end
		end
	end
end

-- The palette's menu on a prefab
function PF.menu(it, x, y, redraw)
	local name = it.prefab
	local info = info_of(name) or {}
	local placing = S.placing ~= nil and S.placing.prefab == name
	local fs, fn = NT.favourite(it.key, it.label, function()
		redraw()
		PF.menu(it, x, y, redraw)
	end)
	local entries = {it.label, {placing and "Stop placing" or "Place", function()
		if placing then
			S.placing = nil
			log:info("kit editor: placing nothing")
			redraw()
		else
			NT.arm(it)
		end
	end}}
	if info.size and not placing then
		entries[#entries + 1] = {"Place free", function()
			NT.arm(it, true)
		end}
	end
	if info.own and (E.session or {}).kind == "default" and (E.session or {}).can
			then
		entries[#entries + 1] = {"Edit", function()
			send({op = "prefab_bench", prefab = name})
			log:info("kit editor: edit the prefab " .. name)
		end}
	end
	if info.own then
		entries[#entries + 1] = {"Rename", function() PF.rename_dialog(name) end}
		entries[#entries + 1] = {"Delete", function() PF.delete_dialog(name) end}
	end
	entries[#entries + 1] = {fs, fn}
	entries[#entries + 1] = {"Cancel", function() end}
	NT.menu(entries, x, y)
	log:info("kit editor: the palette's menu of " .. it.label)
end

function PF.rename_dialog(name)
	local w = dialog()
	local to = name:match("[^/]*$")
	text(w, "Rename the prefab " .. name)
	local r = row(w)
	label(r, "Name:")
	edit(r, to, function(s)
		to = s
	end)
	local br = row(w)
	button(br, "Rename it", function()
		close()
		send({op = "prefab_rename", name = name, to = to})
		log:info("kit editor: rename " .. name .. " to " .. to)
	end)
	button(br, "Cancel", close)
end

function PF.delete_dialog(name)
	local n = (info_of(name) or {}).copies or 0
	local w = dialog()
	text(w, "Delete the prefab " .. name .. "?")
	text(w, n == 0 and "No copy of it is placed." or n == 1 and
			"1 copy is placed: it stays as it is, following nothing." or
			n .. " copies are placed: they stay as they are, following nothing.", DIM)
	if ((info_of(name) or {}).free or 0) > 0 then
		text(w, "A free copy loses its object with the prefab's voxels.", DIM)
	end
	local br = row(w)
	button(br, "Delete it", function()
		close()
		send({op = "prefab_delete", name = name})
		log:info("kit editor: delete " .. name)
	end)
	button(br, "Cancel", close)
	log:info("kit editor: delete " .. name .. "? " .. n .. " copies")
end
end
