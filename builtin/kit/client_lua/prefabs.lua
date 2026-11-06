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

-- [KIT_PREFAB_ROOT] The root's lines in the inspector
function PF.section(w, e)
	local of = tostring(e.prefab.of)
	local info = info_of(of)
	text(w, "Copy of prefab " .. of .. " v" .. tostring(e.prefab.version) ..
			(info and "" or " (deleted)"), DIM)
	if info and info.version ~= e.prefab.version then
		text(w, "Prefab is at v" .. tostring(info.version) ..
				": follows at its next save", DIM)
	end
	if info and info.voxels and (e.prefab.voxels or 0) < info.voxels then
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
	if info and info.size then
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
	if not j.id or not j.pos then
		return
	end
	local e, made = find(j.id)
	if not e or made or type(e.prefab) ~= "table" or not e.pos then
		return
	end
	local info = info_of(e.prefab.of)
	if not (info and info.size) or (PF.pending and PF.pending.id == j.id) then
		return
	end
	PF.pending = {id = j.id,
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

-- A new state: the move's dialog, once the row has moved
function PF.state()
	bench_state()
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
			(e.yaw or 0) == f[4] then
		return
	end
	PF.pending = nil
	if (e.yaw or 0) % 90 ~= 0 then
		E.status = string.format("The voxels stay: turned %g, and a stamp takes "
				.. "multiples of 90", e.yaw)
		log:info("kit editor: " .. E.status)
		return
	end
	PF.stamp_dialog(q.id, f)
end

function PF.refused()
	PF.pending = nil
end

-- The selected roots' boxes, a cell's middle its whole coordinates
function PF.draw(dbg)
	for id in pairs(S.sel) do
		local e, made = find(id)
		local info = e and not made and type(e.prefab) == "table" and e.pos and
				info_of(e.prefab.of)
		if info and info.size then
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
	text(w, n == 1 and "1 copy is placed: it stays as it is, following nothing." or
			n .. " copies are placed: they stay as they are, following nothing.", DIM)
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
