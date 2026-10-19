-- Buildat: apps/floorplanner/main/client_lua/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The floor planner's client: the join dialog, the replica of the document,
-- the chat, and the editor (editor.lua). doc/plan/floorplanner_plan.md is
-- the spec; the server (main.cpp) holds the document and checks everything.
local log = buildat.Logger("floorplanner")
local cereal = require("buildat/extension/cereal")
local magic = require("buildat/extension/urho3d")

local STYLE = magic.cache:GetResource("XMLFile", "ui_utils/res/style.xml")
magic.ui.root.defaultStyle = STYLE
-- Light enough to load again by itself when a phone's browser dropped it in
-- the background (src/client/web/index.html)
buildat.set_reload_on_return(true)

-- The wire types, the same as main.cpp's structs field for field
local ENTITY = {"object",
	{"id", "int32_t"},
	{"type", "string"},
	{"ints", {"unordered_map", "string", "int32_t"}},
	{"strs", {"unordered_map", "string", "string"}},
	{"lists", {"unordered_map", "string", {"array", "int32_t"}}},
}
local TEXT = {"object", {"text", "string"}}
-- The code is the setup code of a plan with no admin, or an invite code
-- for a new account ([FP_ACCESS])
local BATCH = {"object",
	{"seq", "int32_t"},
	{"ops", {"array", {"object", {"op", "byte"}, {"ent", ENTITY}}}},
}
local BATCH_RESULT = {"object",
	{"seq", "int32_t"},
	{"error", "string"},
	{"placeholders", {"unordered_map", "int32_t", "int32_t"}},
}
local CHANGES = {"object",
	{"seq", "int32_t"},
	{"sender", "int32_t"},
	{"ents", {"array", ENTITY}},
	{"deleted", {"array", "int32_t"}},
}

--
-- The replica
--
-- doc.ents[id] is what the server last said about each entity; nothing
-- here changes it but the server's packets. An edit is a batch sent with
-- doc.send(); the result comes back as fp:changes to everybody.
local doc = {
	ents = {},
	privs = {},
	-- Called with (changed_ids, deleted_ids) after every change
	listeners = {},
	-- seq -> {done = function(error, placeholders), kind, inverse}, for
	-- this client's own batches
	pending = {},
	next_seq = 1,
	-- What undoes each batch of this user's, newest last
	undo_stack = {},
	redo_stack = {},
	-- Each voxel volume's voxels: definition id -> {cell key -> palette
	-- entry}, and a count per definition that grows with every change
	voxels = {},
	voxel_version = {},
	-- Other users: peer -> {name, p (their presence), preview (entity id
	-- -> the fields their drag would give it)}
	others = {},
}
local UNDO_DEPTH = 200

function doc.can(priv)
	return doc.privs[priv] == true
end
-- Viewing or editing ([FP_VIEW_EDIT]): the server says which in fp:privs,
-- "edit" while editing and "can_edit" when the user's role would
function doc.set_editing(on)
	buildat.send_packet("fp:set_editing", cereal.binary_output({on = on and 1
			or 0}, {"object", {"on", "byte"}}))
end

function doc.of_type(type)
	local out = {}
	for id, e in pairs(doc.ents) do
		if e.type == type then
			out[#out + 1] = e
		end
	end
	table.sort(out, function(a, b) return a.id < b.id end)
	return out
end

function doc.settings()
	return doc.of_type("settings")[1]
end

-- ops: {{op = "create"|"set"|"delete", ent = {id =, type =, ints =, ...}}}
-- A created entity takes a negative id, unique in the batch, which other ops
-- in it may refer to; done(error, placeholders) gets the real ids.
local OP_CODES = {create = 0, set = 1, delete = 2, restore = 3}
local LAYERED = {node = true, instance = true, image = true}
-- kind: nil for an edit, "undo" or "redo" for what undoes one
function doc.send(ops, done, kind)
	local seq = doc.next_seq
	doc.next_seq = seq + 1
	local wire = {}
	for i, op in ipairs(ops) do
		local e = op.ent
		local ints = e.ints or {}
		-- A new node, instance or picture is the current layout's
		-- ([FP_LAYOUTS]); walls and rooms are their nodes'
		if op.op == "create" and LAYERED[e.type] and not ints.layout then
			ints.layout = doc.layout or 0
		end
		wire[i] = {op = OP_CODES[op.op], ent = {id = e.id, type = e.type or "",
				ints = ints, strs = e.strs or {}, lists = e.lists or {}}}
	end
	doc.pending[seq] = {kind = kind, merge = doc.merge_tag,
			sent = buildat.get_time_us(),
			done = done or function(err)
		if err ~= "" then
			doc.notice("Refused: " .. err)
		end
	end}
	doc.merge_tag = nil
	buildat.send_packet("fp:batch",
			cereal.binary_output({seq = seq, ops = wire}, BATCH))
end

-- A negative id for a new entity, unique for this session
local next_placeholder = -1
function doc.placeholder()
	next_placeholder = next_placeholder - 1
	return next_placeholder
end

local function notify(changed, deleted)
	for _, f in ipairs(doc.listeners) do
		f(changed, deleted)
	end
end

buildat.sub_packet("fp:snapshot", function(data)
	local ents = cereal.binary_input(data, {"array", ENTITY})
	doc.ents = {}
	local changed = {}
	for _, e in ipairs(ents) do
		doc.ents[e.id] = e
		changed[#changed + 1] = e.id
	end
	log:info("Snapshot: " .. #ents .. " entities")
	doc.joined()
	notify(changed, {})
end)

local function same(a, b)
	if type(a) ~= "table" then
		return a == b
	end
	if #a ~= #b then
		return false
	end
	for i = 1, #a do
		if a[i] ~= b[i] then
			return false
		end
	end
	return true
end

local function copy(t)
	local o = {}
	for k, v in pairs(t) do
		o[k] = type(v) == "table" and copy(v) or v
	end
	return o
end

-- **Edits that are one undo step** (user, 2026-10-06: the movement keys'
-- moves during one selection): doc.merge_tag set before doc.send tags
-- that batch, and a batch's inverse whose tag is the undo stack's top's
-- goes into it. `older` is undone last, so its values stay and the newer
-- one's expected values replace its. Only sets merge; nil otherwise.
function doc.merge_inverse(older, newer)
	for _, op in ipairs(older) do
		if op.op ~= "set" then
			return nil
		end
	end
	local out, by_id = copy(older), {}
	for _, op in ipairs(out) do
		by_id[op.ent.id] = op
	end
	for _, op in ipairs(newer) do
		if op.op ~= "set" then
			return nil
		end
		local o = by_id[op.ent.id]
		if not o then
			o = copy(op)
			out[#out + 1] = o
			by_id[op.ent.id] = o
		else
			for _, part in ipairs({"ints", "strs", "lists"}) do
				for k, v in pairs(op.ent[part]) do
					if o.ent[part][k] == nil then
						o.ent[part][k] = v
					end
					o.expect[part][k] = op.expect[part][k]
				end
			end
		end
	end
	out.merge = older.merge
	return out
end

-- What undoes a batch, from what the server says it changed and the
-- replica before it: what it deleted is restored, what it made is
-- deleted, and each changed field is set back. `expect` is what a field
-- was left at, so an undo can skip one somebody else has changed since.
local function inverse_of(c)
	local restores, sets, deletes = {}, {}, {}
	for _, e in ipairs(c.ents) do
		local old = doc.ents[e.id]
		if not old then
			deletes[#deletes + 1] = {op = "delete", ent = {id = e.id}}
		else
			local ent = {id = e.id, ints = {}, strs = {}, lists = {}}
			local expect = {ints = {}, strs = {}, lists = {}}
			local any = false
			for _, part in ipairs({"ints", "strs", "lists"}) do
				for k, v in pairs(e[part]) do
					if not same(old[part][k], v) then
						ent[part][k] = old[part][k]
						expect[part][k] = v
						any = true
					end
				end
			end
			if any then
				sets[#sets + 1] = {op = "set", ent = ent, expect = expect}
			end
		end
	end
	for _, id in ipairs(c.deleted) do
		local old = doc.ents[id]
		if old then
			restores[#restores + 1] = {op = "restore", ent = copy(old)}
		end
	end
	local out = {}
	for _, list in ipairs({restores, sets, deletes}) do
		for _, op in ipairs(list) do
			out[#out + 1] = op
		end
	end
	return out
end

-- An undo or redo, less what has changed under it since: a field somebody
-- else has set is left as they set it
local function still_applies(ops)
	local out, skipped = {}, 0
	for _, op in ipairs(ops) do
		local cur = doc.ents[op.ent.id]
		if op.op == "restore" then
			if cur then
				skipped = skipped + 1
			else
				out[#out + 1] = op
			end
		elseif op.op == "delete" then
			if cur then
				out[#out + 1] = op
			end
		elseif cur then
			local ent = {id = op.ent.id, ints = {}, strs = {}, lists = {}}
			local any = false
			for _, part in ipairs({"ints", "strs", "lists"}) do
				for k, v in pairs(op.ent[part]) do
					if same(cur[part][k], op.expect[part][k]) then
						ent[part][k] = v
						any = true
					else
						skipped = skipped + 1
					end
				end
			end
			if any then
				out[#out + 1] = {op = "set", ent = ent}
			end
		end
	end
	return out, skipped
end

local function step(from, kind)
	local ops = table.remove(from)
	if not ops then
		doc.notice("Nothing to " .. kind)
		return
	end
	if ops.voxels then
		-- Voxels set back, but not where somebody has set them since
		local sets, skipped = {}, 0
		local cur = doc.voxels[ops.def] or {}
		for key, v in pairs(ops.voxels) do
			if (cur[key] or 0) == ops.expect[key] then
				sets[key] = v
			else
				skipped = skipped + 1
			end
		end
		if skipped > 0 then
			doc.notice(skipped .. " voxels changed by somebody else since")
		end
		if next(sets) then
			doc.set_voxels(ops.def, sets, kind)
		end
		return
	end
	local left, skipped = still_applies(ops)
	if skipped > 0 then
		doc.notice(skipped .. " changed by somebody else since; left as is")
	end
	if #left > 0 then
		doc.send(left, nil, kind)
	end
end

function doc.undo()
	step(doc.undo_stack, "undo")
end

function doc.redo()
	step(doc.redo_stack, "redo")
end

buildat.sub_packet("fp:changes", function(data)
	local c = cereal.binary_input(data, CHANGES)
	local own = c.seq >= 0 and doc.pending[c.seq]
	if own then
		own.inverse = inverse_of(c)
		-- [FP_MOVE_FAST] The round trip, for a check's measures
		if doc.on_round_trip then
			doc.on_round_trip((buildat.get_time_us() - own.sent) / 1000)
		end
	end
	local changed = {}
	for _, e in ipairs(c.ents) do
		doc.ents[e.id] = e
		changed[#changed + 1] = e.id
	end
	for _, id in ipairs(c.deleted) do
		doc.ents[id] = nil
	end
	notify(changed, c.deleted)
end)

buildat.sub_packet("fp:batch_result", function(data)
	local r = cereal.binary_input(data, BATCH_RESULT)
	local p = doc.pending[r.seq]
	doc.pending[r.seq] = nil
	if not p then
		return
	end
	-- An edit is undone by its inverse; an undo is redone by its own, and
	-- a redo undone again
	if r.error == "" and p.inverse and #p.inverse > 0 then
		local stack = p.kind == "undo" and doc.redo_stack or doc.undo_stack
		local top = stack[#stack]
		local merged = p.merge and not p.kind and top and top.merge == p.merge
				and doc.merge_inverse(top, p.inverse)
		if merged then
			stack[#stack] = merged
		else
			p.inverse.merge = not p.kind and p.merge or nil
			stack[#stack + 1] = p.inverse
		end
		if #stack > UNDO_DEPTH then
			table.remove(stack, 1)
		end
		if not p.kind then
			doc.redo_stack = {}
		end
	end
	p.done(r.error, r.placeholders)
end)

-- The pictures the server has to trace over, by file name
doc.images = {}
buildat.sub_packet("fp:images", function(data)
	doc.images = cereal.binary_input(data, {"array", "string"})
	if doc.privs_changed then
		doc.privs_changed()
	end
end)

-- The admin's menus and the password change ([FP_ACCESS] 4): the
-- accounts, the open invites and the access settings, which the server
-- sends an admin at the join and after every change; what a request came to
local ADMIN = {"object", {"cmd", "string"}, {"name", "string"},
		{"arg", "string"}, {"on", "byte"}}
-- A plan's members ([FP_PLANS] 5): its owner, the groups it is shared
-- with ([FP_GROUPS]), and the accounts with a role in it
local MEMBERS = {"object", {"plan", "string"}, {"owner", "string"},
	{"groups", "string"},
	{"members", {"array", {"object", {"name", "string"}, {"role", "string"}}}},
}
doc.members = nil
function doc.plan_admin(cmd, name, arg)
	buildat.send_packet("fp:plan_admin", cereal.binary_output({cmd = cmd,
			name = name or "", arg = arg or "", on = 0}, ADMIN))
end
buildat.sub_packet("fp:members", function(data)
	doc.members = cereal.binary_input(data, MEMBERS)
	if doc.members_changed then
		doc.members_changed()
	end
end)
-- The server's accounts ([VANILLA_PUBLIC] 2): the join, and the admin's and
-- the user's own requests, are builtin/accounts'
local _, accounts_err, accounts = buildat.run_script_file("accounts/accounts.lua")
if type(accounts) ~= "table" then
	error("floorplanner: could not load accounts.lua: " .. tostring(accounts_err))
end
-- The editor's pause menu opens its Users and password pages
doc.accounts = accounts
-- The tutorial ([FP_TUTORIAL]), which goes on after a reload
do
	local _, terr, make = buildat.run_script_file("main/tutorial.lua")
	if type(make) ~= "function" then
		error("floorplanner: could not load tutorial.lua: " .. tostring(terr))
	end
	doc.tutorial = make(doc)
end
-- A plan members page's own requests' results
buildat.sub_packet("fp:admin_result", function(data)
	doc.admin_message = cereal.binary_input(data, TEXT).text
	if doc.members_changed then
		doc.members_changed()
	end
end)

buildat.sub_packet("fp:privs", function(data)
	doc.privs = {}
	local list = cereal.binary_input(data, {"array", "string"})
	for _, p in ipairs(list) do
		doc.privs[p] = true
	end
	log:info("Privileges: " .. table.concat(list, " "))
	-- A check's edit, once: editing on, then one palette entry made
	-- ([FP_ABUSE]'s check)
	if buildat.get_env("BUILDAT_FP_EDIT") and not doc.edit_script_done then
		if doc.privs.edit then
			doc.edit_script_done = true
			doc.send({{op = "create", ent = {id = doc.placeholder(),
					type = "palette"}}}, function(err)
				log:info("Scripted edit: " .. (err == "" and "done" or err))
			end)
		elseif doc.privs.can_edit then
			doc.set_editing(true)
		end
	end
	if doc.privs_changed then
		doc.privs_changed()
	end
end)

--
-- Voxels
--
local VOXELS = {"object", {"seq", "int32_t"}, {"def", "int32_t"},
	{"sets", {"unordered_map", "int32_t", "int32_t"}}}
-- The same bytes written as pairs: cereal.binary_output cannot write a map
-- with number keys, since tracing one turns the key into a string in place
-- (lua_tostring in src/lua_bindings/cereal.cpp), which breaks lua_next
local VOXELS_OUT = {"object", {"seq", "int32_t"}, {"def", "int32_t"},
	{"sets", {"array", {"object", {"k", "int32_t"}, {"v", "int32_t"}}}}}
local VOXELS_RESULT = {"object", {"seq", "int32_t"}, {"error", "string"}}

-- A cell of a volume as one number: x, y and z from -128 to 127
function doc.voxel_key(x, y, z)
	return (x + 128) + (y + 128) * 256 + (z + 128) * 65536
end

function doc.voxel_cell(key)
	return key % 256 - 128, math.floor(key / 256) % 256 - 128,
			math.floor(key / 65536) - 128
end

-- sets: cell key -> palette entry, 0 to empty the cell. Undone like a
-- batch: what the cells held before, back.
local voxel_pending = {}
function doc.set_voxels(def, sets, kind)
	local seq = doc.next_seq
	doc.next_seq = seq + 1
	local cur = doc.voxels[def] or {}
	local inverse, expect = {}, {}
	for key, v in pairs(sets) do
		inverse[key] = cur[key] or 0
		expect[key] = v
	end
	voxel_pending[seq] = {kind = kind, undo = {voxels = inverse, def = def,
			expect = expect}}
	local pairs_ = {}
	for key, v in pairs(sets) do
		pairs_[#pairs_ + 1] = {k = key, v = v}
	end
	buildat.send_packet("fp:voxels", cereal.binary_output({seq = seq,
			def = def, sets = pairs_}, VOXELS_OUT))
end

buildat.sub_packet("fp:voxels", function(data)
	local v = cereal.binary_input(data, VOXELS)
	local vox = doc.voxels[v.def] or {}
	doc.voxels[v.def] = vox
	for key, m in pairs(v.sets) do
		vox[key] = m ~= 0 and m or nil
	end
	doc.voxel_version[v.def] = (doc.voxel_version[v.def] or 0) + 1
	if doc.voxels_changed then
		doc.voxels_changed(v.def)
	end
end)

buildat.sub_packet("fp:voxels_result", function(data)
	local r = cereal.binary_input(data, VOXELS_RESULT)
	local p = voxel_pending[r.seq]
	voxel_pending[r.seq] = nil
	if not p then
		return
	end
	if r.error ~= "" then
		doc.notice("Refused: " .. r.error)
		return
	end
	local stack = p.kind == "undo" and doc.redo_stack or doc.undo_stack
	stack[#stack + 1] = p.undo
	if #stack > UNDO_DEPTH then
		table.remove(stack, 1)
	end
	if not p.kind then
		doc.redo_stack = {}
	end
end)

--
-- Drag locks, previews and presence
--
local LOCK = {"object", {"seq", "int32_t"}, {"ids", {"array", "int32_t"}}}
local LOCK_RESULT = {"object", {"seq", "int32_t"}, {"error", "string"}}
local PREVIEW = {"object", {"peer", "int32_t"}, {"ents", {"array", ENTITY}}}
local PRESENCE = {"object",
	{"view", "byte"},
	{"cx", "int32_t"}, {"cz", "int32_t"},
	{"px", "int32_t"}, {"py", "int32_t"}, {"pz", "int32_t"},
	{"yaw", "int32_t"}, {"pitch", "int32_t"},
	{"sel", {"array", "int32_t"}},
}
local PRESENCE_OUT = {"object", {"peer", "int32_t"}, {"name", "string"},
	{"p", PRESENCE}}

-- A drag takes the lock on what it moves; refused(why) when somebody else
-- holds it
local lock_waiting = {}
function doc.lock(ids, refused)
	local seq = doc.next_seq
	doc.next_seq = seq + 1
	lock_waiting[seq] = refused
	buildat.send_packet("fp:lock", cereal.binary_output({seq = seq, ids = ids},
			LOCK))
end

function doc.unlock()
	buildat.send_packet("fp:unlock", "")
end

buildat.sub_packet("fp:lock_result", function(data)
	local r = cereal.binary_input(data, LOCK_RESULT)
	local refused = lock_waiting[r.seq]
	lock_waiting[r.seq] = nil
	if refused and r.error ~= "" then
		refused(r.error)
	end
end)

-- ents: {{id =, ints = {...}}}, what a drag would make of them
function doc.preview(ents)
	local wire = {}
	for i, e in ipairs(ents) do
		wire[i] = {id = e.id, type = "", ints = e.ints, strs = {}, lists = {}}
	end
	buildat.send_packet("fp:preview", cereal.binary_output(wire,
			{"array", ENTITY}))
end

local function other(peer)
	doc.others[peer] = doc.others[peer] or {preview = {}}
	return doc.others[peer]
end

buildat.sub_packet("fp:preview", function(data)
	local p = cereal.binary_input(data, PREVIEW)
	local o = other(p.peer)
	o.preview = {}
	for _, e in ipairs(p.ents) do
		o.preview[e.id] = e.ints
	end
	if doc.others_changed then
		doc.others_changed()
	end
end)

-- The fields entity id would have if the others' drags landed now, or nil
function doc.previewed(id)
	for _, o in pairs(doc.others) do
		if o.preview[id] then
			return o.preview[id]
		end
	end
	return nil
end

function doc.send_presence(p)
	buildat.send_packet("fp:presence", cereal.binary_output(p, PRESENCE))
end

buildat.sub_packet("fp:presence", function(data)
	local r = cereal.binary_input(data, PRESENCE_OUT)
	local o = other(r.peer)
	o.name, o.p = r.name, r.p
end)

buildat.sub_packet("fp:gone", function(data)
	local peer = cereal.binary_input(data, {"object", {"peer", "int32_t"}}).peer
	doc.others[peer] = nil
	if doc.others_changed then
		doc.others_changed()
	end
end)

--
-- Messages: the chat, and the notices the client gives itself
--
local MSG_LINES = 8
local MSG_SECONDS = 20
local messages = {}
local msg_text = magic.ui.root:CreateChild("Text")
msg_text:SetFont(magic.cache:GetResource("Font", buildat.font_sans), 14)
msg_text.horizontalAlignment = magic.HA_LEFT
msg_text.verticalAlignment = magic.VA_BOTTOM
msg_text:SetPosition(10, -44)
msg_text:SetTextEffect(magic.TE_SHADOW)
msg_text.priority = 100

local function redraw_messages()
	local now = buildat.get_time_us()
	local keep = {}
	for _, m in ipairs(messages) do
		if now - m.t < MSG_SECONDS * 1000000 then
			keep[#keep + 1] = m
		end
	end
	while #keep > MSG_LINES do
		table.remove(keep, 1)
	end
	messages = keep
	local lines = {}
	for _, m in ipairs(messages) do
		lines[#lines + 1] = m.text
	end
	local text = table.concat(lines, "\n")
	if text ~= msg_text.text then
		msg_text:SetText(text)
	end
end

-- A line over the editor for a while
local function show_message(text)
	messages[#messages + 1] = {text = text, t = buildat.get_time_us()}
	redraw_messages()
end

function doc.notice(text)
	log:info(text)
	show_message(text)
	-- The chat console's too ([CHAT_CONSOLE]), which the pause menu opens
	accounts.chat_add(text, "plan")
end

-- **The chat by group** ([FP_GROUP_CHAT]): the plan's own chat, "This
-- plan", and one for each group the user is in. What is sent goes to the
-- one the chat page has picked; over the editor show the plan's lines
-- and the picked group's.
accounts.chat_channels = function()
	local list = {{key = "plan", label = "This plan"}}
	for _, g in ipairs(doc.groups and doc.groups.groups or {}) do
		list[#list + 1] = {key = "g" .. g.id, label = g.name}
	end
	return list
end
local GROUP_CHAT = {"object", {"group", "int32_t"}, {"text", "string"},
		{"old", "byte"}}
accounts.chat_send = function(text, key)
	local group = key and tonumber(key:match("^g(%d+)$"))
	if group then
		buildat.send_packet("fp:group_chat", cereal.binary_output({
				group = group, text = text, old = 0}, GROUP_CHAT))
	else
		buildat.send_packet("fp:chat", cereal.binary_output({text = text},
				TEXT))
	end
end

buildat.sub_packet("fp:chat", function(data)
	doc.notice(cereal.binary_input(data, TEXT).text)
end)

buildat.sub_packet("fp:group_chat", function(data)
	local c = cereal.binary_input(data, GROUP_CHAT)
	local key = "g" .. c.group
	log:info("group " .. c.group .. ": " .. c.text)
	accounts.chat_add(c.text, key, c.old == 1)
	if c.old ~= 1 and accounts.chat_shown() == key then
		show_message(c.text)
	end
end)


local chat_input = nil

-- True while a text field has the keyboard, so the editor leaves keys alone
function doc.typing()
	local f = magic.ui.focusElement
	return f ~= nil and f:GetTypeName() == "LineEdit"
end

local function close_chat()
	if chat_input then
		chat_input:Remove()
		chat_input = nil
		magic.ui:SetFocusElement(nil)
	end
end

local function open_chat(initial)
	if chat_input then
		return
	end
	chat_input = magic.ui.root:CreateChild("LineEdit")
	chat_input.textCopyable = true
	chat_input.textSelectable = true
	chat_input:SetStyleAuto()
	chat_input.horizontalAlignment = magic.HA_LEFT
	chat_input.verticalAlignment = magic.VA_BOTTOM
	chat_input.size = magic.IntVector2(
			math.min(560, magic.ui.root.width - 20), 26)
	chat_input:SetPosition(10, -10)
	chat_input:SetText(initial or "")
	chat_input:SetFocus(true)
	magic.SubscribeToEvent(chat_input, "TextFinished", function(self)
		local text = chat_input:GetText()
		close_chat()
		if text ~= "" then
			accounts.chat_send(text, accounts.chat_shown())
		end
	end)
end

--
-- The join dialog
--
local login_window = nil
-- A window of the plans pages: `width` wide, or the
-- screen's width less a margin on a narrow one, a phone's ([FP_TOUCH] 2),
-- and its texts wrap to it
local function page_window(width)
	-- Not a groups page or the plans, until one says it is
	doc.groups_page = nil
	doc.on_plans = false
	return accounts.page_window(width)
end

local page_text = accounts.page_text

-- The plans ([FP_PLANS] 4): after the join, the ones this user may read,
-- to open one or make a new one, which is theirs
local PLAN_ROWS = {"array", {"object", {"name", "string"}, {"owner", "string"},
		{"role", "string"}, {"here", "int32_t"}}}
doc.plans = {}
local auto_plan_done = false

-- **A space in a typed name is an underscore** (user, 2026-10-01): a name
-- can be written naturally, and the plan's directory still has none. The
-- ends are trimmed, and a run of spaces is one _.
local function plan_name(text)
	return (text:match("^%s*(.-)%s*$"):gsub("%s+", "_"))
end

local function open_plan(name, create)
	buildat.send_packet("fp:open", cereal.binary_output(
			{name = plan_name(name), create = create and 1 or 0},
			{"object", {"name", "string"}, {"create", "byte"}}))
end

-- **A plan's backups** ([FP_BACKUPS]): the list, for anyone who reads the
-- plan, and one opened to look at, a plan everyone in only reads; Copy
-- this plan keeps it. doc.backup is {of, label} while in one.
local BACKUPS = {"object", {"plan", "string"}, {"rows", {"array",
	{"object", {"id", "string"}, {"label", "string"}}}}}
doc.backups = nil
function doc.request_backups()
	doc.backups = nil
	buildat.send_packet("fp:backups", "")
end
-- **The branch point** ([FP_GHOST]): what it is ("" with none), and
-- with the plan's ghost setting on its entities by id, else nil; set,
-- imported from another plan or removed by an editor
local GHOST = {"object", {"info", "string"}, {"ents", {"array", ENTITY}}}
doc.ghost_info, doc.ghost, doc.ghost_gen = "", nil, 0
buildat.sub_packet("fp:ghost", function(data)
	local g = cereal.binary_input(data, GHOST)
	doc.ghost_info = g.info
	doc.ghost = nil
	for _, e in ipairs(g.ents) do
		doc.ghost = doc.ghost or {}
		doc.ghost[e.id] = e
	end
	doc.ghost_gen = doc.ghost_gen + 1
	if doc.ghost_changed then
		doc.ghost_changed()
	end
end)
function doc.branch_point(cmd, arg)
	buildat.send_packet("fp:branch_point", cereal.binary_output(
			{cmd = cmd, arg = arg or ""},
			{"object", {"cmd", "string"}, {"arg", "string"}}))
end
buildat.sub_packet("fp:backups", function(data)
	doc.backups = cereal.binary_input(data, BACKUPS)
	if doc.backups_changed then
		doc.backups_changed()
	end
end)
function doc.open_backup(id)
	buildat.send_packet("fp:open_backup", cereal.binary_output({text = id},
			TEXT))
end
buildat.sub_packet("fp:backup", function(data)
	doc.backup = cereal.binary_input(data, {"object", {"of", "string"},
			{"label", "string"}, {"restore", "byte"}})
end)
-- The backup looked at put back as the plan it is of, for one who may
-- edit that; everyone in the plan gets it again
function doc.restore_backup()
	buildat.send_packet("fp:restore_backup", "")
end
-- Out of a backup, into the plan it is of
function doc.open_plan(name)
	open_plan(name, false)
end

local ROLE_TEXT = {admin = "admin", owner = "yours", editor = "can edit",
		viewer = "can read"}

local show_plans
local in_picker_menu = false

-- **The menu without a plan** (user, 2026-10-02): what needs no plan
-- open -- the chat, the server's accounts and Starport page, the user's
-- own account -- from the plan picker. A plan's view settings (client
-- settings, keys, viewports) are the editor's, in the plan's menu.
local picker_menu
picker_menu = function()
	if login_window then
		login_window:Remove()
	end
	in_picker_menu = true
	local w = page_window(420)
	login_window = w
	log:info("The plan picker's menu shown")
	page_text(w, "Floor planner")
	local function page(open)
		return function()
			login_window:Remove()
			login_window = nil
			open(function() picker_menu() end)
		end
	end
	local b = accounts.page_button
	b(w, "Back to the plans", function() show_plans() end)
	b(w, "Chat...", page(accounts.chat_page))
	-- My account... local or not ([ACCOUNT_BUTTON]); Accounts... is reached
	-- through it now (account_page's own button)
	b(w, "My account...", page(accounts.account_page))
	if not doc.is_local then
		b(w, "Report this server...", function()
			require("buildat/extension/starport").open_report_here()
		end)
	end
	if buildat.get_env("BUILDAT_PAGE_HTTPS") == nil then
		b(w, "Leave to the launcher", function() buildat.leave() end)
		b(w, "Quit", function() buildat.quit() end)
	elseif not doc.is_local then
		b(w, "Log out", accounts.logout)
	end
end

show_plans = function(message)
	in_picker_menu = false
	if login_window then
		login_window:Remove()
	end
	local w = page_window(420)
	login_window = w
	local function text(t, color)
		page_text(w, t, color)
	end
	local function button(t, f)
		accounts.page_button(w, t, f)
	end
	doc.on_plans = true
	log:info("Plan picker: " .. #doc.plans .. " plans")
	text("Floor planner: open a plan")
	if message and message ~= "" then
		text(message, magic.Color(1.0, 0.4, 0.4))
	end
	-- The invites to a group ([FP_GROUPS]), here rather than in a dialog
	-- that the page, drawn again, would cover
	for _, inv in ipairs(doc.groups and doc.groups.invites or {}) do
		log:info("Invited to the group " .. inv.name .. " by " .. inv.by)
		text(inv.by .. " invites you to the group \"" .. inv.name .. "\"",
				magic.Color(1.0, 0.8, 0.4))
		local r = w:CreateChild("UIElement")
		r:SetLayout(magic.LM_HORIZONTAL, 6, magic.IntRect(0, 0, 0, 0))
		-- [FP_ABUSE] 2: the block on a row of its own, under the two
		local r2 = w:CreateChild("UIElement")
		r2:SetLayout(magic.LM_HORIZONTAL, 6, magic.IntRect(0, 0, 0, 0))
		for i, a in ipairs({{"Accept", "accept"}, {"Decline", "decline"},
				{"No invites from this group", "block"}}) do
			local b = (i < 3 and r or r2):CreateChild("Button")
			b:SetStyleAuto()
			b.minHeight = 28
			local bt = b:CreateChild("Text")
			bt:SetStyleAuto()
			bt:SetText(a[1])
			bt:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
			magic.SubscribeToEvent(b, "Released", function()
				doc.group_cmd(a[2], inv.id)
			end)
		end
	end
	-- The one this user was in last, first
	local last = buildat.storage_read("plan")
	local rows = {}
	for _, p in ipairs(doc.plans) do
		if p.name == last then
			table.insert(rows, 1, p)
		else
			rows[#rows + 1] = p
		end
	end
	for _, p in ipairs(rows) do
		local label = p.name .. "  (" .. (ROLE_TEXT[p.role] or p.role) ..
				(p.owner ~= "" and p.role ~= "owner" and ", " .. p.owner .. "'s" or
				"") .. (p.here > 0 and ", " .. p.here .. " here" or "") .. ")"
		button(label, function() open_plan(p.name, false) end)
	end
	if #rows == 0 then
		text("There are no plans yet")
	end
	text("Or a new one, by name:")
	local e = w:CreateChild("LineEdit")
	e:SetStyleAuto()
	e.minHeight = 26
	e.textSelectable = true
	local function create()
		local n = e:GetText()
		if n ~= "" then
			open_plan(n, true)
		end
	end
	magic.SubscribeToEvent(e, "TextFinished", create)
	button("New plan", create)
	button("Import a plan...", function() doc.show_import() end)
	button("Groups...", function() doc.show_groups() end)
	-- The basics, step by step ([FP_TUTORIAL])
	button("Tutorial", function() doc.tutorial.start() end)
	button("Menu...", picker_menu)
	e:SetFocus(true)
end

-- **A plan from a file** ([FP_EXPORT] 3): on the web the browser's file
-- picker; on native the client's list of <user>/exports, where an export
-- goes. Then a name for it, which a new plan of this user's gets.
local IMPORT = {"object", {"name", "string"}, {"file", "string"}}
local picking = false

local function page(title)
	if login_window then
		login_window:Remove()
	end
	local w = page_window(420)
	login_window = w
	local function text(t, color)
		page_text(w, t, color)
	end
	local function button(t, f)
		accounts.page_button(w, t, f)
	end
	text(title)
	return w, text, button
end

-- The file being imported, for its page again when the server refuses
local importing = nil

local function import_as(file_name, data, message)
	importing = {file_name, data}
	local w, text, button = page("Import " .. file_name .. " as a new plan:")
	if message then
		text(message, magic.Color(1.0, 0.4, 0.4))
	end
	-- The file's name as a plan's: letters, digits, _ and -
	local name = file_name:gsub("%.fpplan$", ""):gsub("[^%w_%-]", "_")
			:gsub("^_+", ""):sub(1, 40)
	local e = w:CreateChild("LineEdit")
	e:SetStyleAuto()
	e.minHeight = 26
	e.textSelectable = true
	e:SetText(name ~= "" and name or "imported")
	local function go()
		local n = plan_name(e:GetText())
		if n == "" then
			return
		end
		text("Sending " .. math.floor(#data / 1024 + 0.5) .. " KiB...")
		buildat.send_packet("fp:import", cereal.binary_output(
				{name = n, file = data}, IMPORT))
	end
	magic.SubscribeToEvent(e, "TextFinished", go)
	button("Import", go)
	button("Back", function()
		importing = nil
		show_plans()
	end)
	e:SetFocus(true)
end

function doc.show_import(message)
	local _, text, button = page("Import a plan from a file (.fpplan)")
	if message then
		text(message, magic.Color(1.0, 0.4, 0.4))
	end
	-- The browser's picker, or on native the client's list of
	-- <user>/exports, where "Export this plan" puts them
	button("Choose a file...", function()
		picking = buildat.pick_file(".fpplan")
	end)
	button("Back", function() show_plans() end)
end

-- **Groups** ([FP_GROUPS]; user, 2026-10-07): a user's groups, their
-- members and the plans shared into them, the invites to the user, and
-- what the user's plans take of their storage. The server sends it at
-- the join and after every change; a group's admins invite, remove and
-- make admins, and any member shares their own plans into it.
local GROUPS = {"object",
	{"groups", {"array", {"object", {"id", "int32_t"}, {"name", "string"},
		{"role", "string"},
		{"members", {"unordered_map", "string", "string"}},
		{"invites", {"array", "string"}},
		{"shares", {"array", {"object", {"plan", "string"},
			{"rest", {"object", {"owner", "string"}, {"role", "string"}}}}}},
		-- [FP_ABUSE] 1: whether the group is trusted, and who in it is not
		{"trusted", "byte"}, {"untrusted", {"array", "string"}},
	}}},
	{"invites", {"array", {"object", {"id", "int32_t"}, {"name", "string"},
		{"by", "string"}}}},
	{"own_plans", {"array", "string"}},
	{"used_kib", "int32_t"}, {"limit_kib", "int32_t"},
}
local GROUP_REQUEST = {"object", {"cmd", "string"}, {"group", "int32_t"},
		{"name", "string"}, {"arg", "string"}}
doc.groups = nil
doc.groups_page = nil -- the open groups page's redraw
local group_message = nil
local invites_asked = {}

local function group_cmd(cmd, group, name, arg)
	buildat.send_packet("fp:group", cereal.binary_output({cmd = cmd,
			group = group or 0, name = name or "", arg = arg or ""},
			GROUP_REQUEST))
end
doc.group_cmd = group_cmd

-- An invite asks at once: in a plan by a dialog, on the plans page in
-- its list; again at the next join if not answered
local function ask_invites()
	for _, inv in ipairs(doc.groups.invites) do
		if not invites_asked[inv.id] then
			invites_asked[inv.id] = true
			log:info("Invited to the group " .. inv.name .. " by " .. inv.by)
			require("buildat/extension/ui_utils").show_confirm_dialog(
					inv.by .. " invites you to the group \"" .. inv.name .. "\"",
					function() group_cmd("accept", inv.id) end,
					function() group_cmd("decline", inv.id) end, "Accept",
					"Decline")
			return
		end
	end
end

local group_script_done = false
-- The script's requests not answered yet; each has one fp:group_result
local group_script_left = 0
buildat.sub_packet("fp:groups", function(data)
	doc.groups = cereal.binary_input(data, GROUPS)
	log:info("Groups: " .. #doc.groups.groups .. ", invites to me: " ..
			#doc.groups.invites)
	-- A check's requests, a line each, "cmd group [name [arg]]", once
	local script = buildat.get_env("BUILDAT_FP_GROUP")
	if script and not group_script_done then
		group_script_done = true
		for l in script:gmatch("[^\n]+") do
			local cmd, group, name, arg = l:match("^(%S+)%s+(%d+)%s*(%S*)%s*(%S*)")
			if cmd then
				group_script_left = group_script_left + 1
				group_cmd(cmd, tonumber(group), name, arg)
			end
		end
	end
	-- And a check's chat lines, "key text" a line ("plan" or "g<id>"), once
	local say = buildat.get_env("BUILDAT_FP_CHAT")
	if say and not doc.chat_script_done then
		doc.chat_script_done = true
		for l in say:gmatch("[^\n]+") do
			local key, text = l:match("^(%S+)%s+(.+)$")
			if key then
				accounts.chat_send(text, key)
			end
		end
	end
	if doc.in_plan then
		ask_invites()
	elseif doc.on_plans then
		show_plans()
	end
	if doc.groups_page then
		doc.groups_page()
	end
end)
buildat.sub_packet("fp:group_result", function(data)
	local t = cereal.binary_input(data, TEXT).text
	if t ~= "" then
		log:info("Group: " .. t)
		group_message = t
		if doc.groups_page then
			doc.groups_page()
		end
	end
	-- After the answer's own line
	if group_script_left > 0 then
		group_script_left = group_script_left - 1
		if group_script_left == 0 then
			log:info("Group script: done")
		end
	end
end)

local function hrow(w)
	local r = w:CreateChild("UIElement")
	r:SetLayout(magic.LM_HORIZONTAL, 6, magic.IntRect(0, 0, 0, 0))
	return r
end
local function small_button(r, t, f)
	local b = r:CreateChild("Button")
	b:SetStyleAuto()
	b.minHeight = 26
	local bt = b:CreateChild("Text")
	bt:SetStyleAuto()
	bt:SetText(t)
	bt:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
	b.minWidth = bt.width + 16
	magic.SubscribeToEvent(b, "Released", f)
	return b
end
local function row_text(r, t)
	local l = r:CreateChild("Text")
	l:SetStyleAuto()
	l:SetText(t)
	l.minWidth = 150
	return l
end
local function name_field(w, on_go)
	local e = w:CreateChild("LineEdit")
	e:SetStyleAuto()
	e.minHeight = 26
	e.textSelectable = true
	magic.SubscribeToEvent(e, "TextFinished", function() on_go(e:GetText()) end)
	return e
end
local function kib_text(kib)
	return string.format("%.1f MB", kib / 1024)
end

local function show_group(id)
	local g = nil
	for _, x in ipairs(doc.groups.groups) do
		if x.id == id then
			g = x
		end
	end
	if not g then
		return doc.show_groups()
	end
	local w, text, button = page("Group: " .. g.name)
	doc.groups_page = function() show_group(id) end
	if group_message then
		text(group_message, magic.Color(1.0, 0.4, 0.4))
		group_message = nil
	end
	local me = accounts.name
	local admin = g.role == "admin"
	-- [FP_ABUSE] 1: trust comes through a trusted group only
	local new = {}
	for _, n in ipairs(g.untrusted) do
		new[n] = true
	end
	text(g.trusted == 1 and "A trusted group: a new member who edits on " ..
			"3 days here is trusted, or when an admin vouches for them." or
			"Not a trusted group: it leads to no trust until every admin " ..
			"of it is trusted.")
	text("Members:")
	local names = {}
	for n in pairs(g.members) do
		names[#names + 1] = n
	end
	table.sort(names)
	for _, n in ipairs(names) do
		local r = hrow(w)
		row_text(r, n .. (g.members[n] == "admin" and " (admin)" or "") ..
				(new[n] and " (new)" or ""))
		if admin and g.trusted == 1 and new[n] and n ~= me then
			small_button(r, "Vouch", function() group_cmd("vouch", id, n) end)
		end
		if admin and n ~= me then
			if g.members[n] == "admin" then
				small_button(r, "Not admin", function() group_cmd("admin", id, n, "0") end)
			else
				small_button(r, "Make admin", function() group_cmd("admin", id, n, "1") end)
			end
			small_button(r, "Remove", function() group_cmd("remove", id, n) end)
		end
	end
	if admin then
		for _, n in ipairs(g.invites) do
			local r = hrow(w)
			row_text(r, n .. " (invited)")
			small_button(r, "Cancel the invite", function() group_cmd("cancel", id, n) end)
		end
		text("Invite by name:")
		local e = name_field(w, function(t)
			if t ~= "" then
				group_cmd("invite", id, t)
			end
		end)
		button("Invite", function()
			if e:GetText() ~= "" then
				group_cmd("invite", id, e:GetText())
			end
		end)
	end
	text("Plans shared here (open one from the plans; a copy is yours):")
	local shared = {}
	for _, sh in ipairs(g.shares) do
		shared[sh.plan] = true
		local r = hrow(w)
		row_text(r, sh.plan .. " (" .. sh.rest.owner .. "'s, " ..
				(sh.rest.role == "editor" and "can edit" or "can read") .. ")")
		if sh.rest.owner == me then
			local other = sh.rest.role == "editor" and "viewer" or "editor"
			small_button(r, other == "editor" and "Make editable" or
					"Make read-only", function()
				group_cmd("share", id, sh.plan, other)
			end)
			small_button(r, "Unshare", function() group_cmd("unshare", id, sh.plan) end)
		end
	end
	if #g.shares == 0 then
		text("  none yet")
	end
	local first = true
	for _, plan in ipairs(doc.groups.own_plans) do
		if not shared[plan] then
			if first then
				text("Share a plan of yours:")
				first = false
			end
			local r = hrow(w)
			row_text(r, plan)
			small_button(r, "Read-only", function() group_cmd("share", id, plan, "viewer") end)
			small_button(r, "Editable", function() group_cmd("share", id, plan, "editor") end)
		end
	end
	button("Leave the group", function() group_cmd("leave", id) end)
	if admin then
		button("Delete the group", function()
			require("buildat/extension/ui_utils").show_confirm_dialog(
					"Delete the group \"" .. g.name .. "\"? Its plans stay " ..
					"their owners'; they are no longer shared here.",
					function() group_cmd("delete", id) end, nil, "Delete")
		end)
	end
	button("Back", function() doc.show_groups() end)
end

function doc.show_groups()
	if not doc.groups then
		doc.groups_page = doc.show_groups
		group_cmd("list")
		return
	end
	local w, text, button = page("Groups")
	doc.groups_page = doc.show_groups
	if group_message then
		text(group_message, magic.Color(1.0, 0.4, 0.4))
		group_message = nil
	end
	local gs = doc.groups
	text("Your plans take " .. kib_text(gs.used_kib) ..
			(gs.limit_kib > 0 and " of " .. kib_text(gs.limit_kib) or ""))
	for _, g in ipairs(gs.groups) do
		local n = 0
		for _ in pairs(g.members) do
			n = n + 1
		end
		button(g.name .. "  (" .. n .. (n == 1 and " member" or " members") ..
				(g.role == "admin" and ", admin" or "") ..
				(g.trusted == 1 and ", trusted" or "") .. ")", function()
			show_group(g.id)
		end)
	end
	if #gs.groups == 0 then
		text("You are in no group. A group's members share plans with " ..
				"each other.")
	end
	text("A new group, by name:")
	local e = name_field(w, function(t)
		if t ~= "" then
			group_cmd("create", 0, t)
		end
	end)
	button("Create group", function()
		if e:GetText() ~= "" then
			group_cmd("create", 0, e:GetText())
		end
	end)
	button("Back", function() show_plans() end)
end

-- The picked file, once it has been read
local function poll_picked()
	if not picking then
		return
	end
	local file_name, data = buildat.picked_file()
	if file_name then
		picking = false
		import_as(file_name, data)
	elseif data then
		picking = false
		doc.show_import(data)
	end
end

-- The open plan as a file: the server sends it, and the client saves it
-- as a download or into <user>/exports
function doc.export_plan()
	buildat.send_packet("fp:export", "")
end

buildat.sub_packet("fp:export_data", function(data)
	local r = cereal.binary_input(data, {"object", {"error", "string"},
			{"name", "string"}, {"file", "string"}})
	if r.error ~= "" then
		doc.notice("Not exported: " .. r.error)
		return
	end
	local path, why = buildat.save_file(r.name .. ".fpplan", r.file)
	if not path then
		doc.notice("Not exported: " .. why)
	elseif path == "" then
		doc.notice("Exported " .. r.name .. ".fpplan (" ..
				math.floor(#r.file / 1024 + 0.5) .. " KiB): see your downloads")
	else
		doc.notice("Exported to " .. path)
	end
end)

buildat.sub_packet("fp:plans", function(data)
	doc.plans = cereal.binary_input(data, PLAN_ROWS)
	local list = {}
	for _, p in ipairs(doc.plans) do
		list[#list + 1] = p.name .. " (" .. p.role .. ")"
	end
	log:info("Plans: " .. table.concat(list, ", "))
	if doc.in_plan then
		return
	end
	-- A scripted client's plan, or the one the launcher named, once: opened,
	-- or made when there is none of the name
	if not auto_plan_done then
		auto_plan_done = true
		local want = buildat.get_env("BUILDAT_FP_PLAN")
		if not want and doc.launch_plan and doc.launch_plan ~= "" then
			want = doc.launch_plan
		end
		-- **Else the plan this client had open** (user, 2026-09-30), when
		-- it is still one this user may open; the editor puts its view back
		local last = buildat.storage_read("plan") or ""
		if not want and last ~= "" then
			for _, p in ipairs(doc.plans) do
				if p.name == last then
					log:info("Opening the plan open last: " .. last)
					open_plan(last, false)
					return
				end
			end
		end
		if want then
			local exists = false
			for _, p in ipairs(doc.plans) do
				exists = exists or p.name == want
			end
			open_plan(want, not exists)
			return
		end
	end
	show_plans()
end)

buildat.sub_packet("fp:open_result", function(data)
	local err = cereal.binary_input(data, TEXT).text
	if err == "" then
		return
	end
	log:info("Plan refused: " .. err)
	if importing then
		import_as(importing[1], importing[2], err)
	elseif doc.in_plan then
		doc.notice(err)
	else
		show_plans(err)
	end
end)

buildat.sub_packet("fp:entered", function(data)
	importing = nil
	doc.plan_name = cereal.binary_input(data, TEXT).text
	doc.in_plan = true
	doc.view_restored = false
	doc.backup = nil
	-- A backup (its name begins with _) is not what a next join opens
	if doc.plan_name:sub(1, 1) ~= "_" then
		buildat.storage_write("plan", doc.plan_name)
	end
	log:info("Entered the plan " .. doc.plan_name)
	-- A check's copy of the first plan entered
	local copy = buildat.get_env("BUILDAT_FP_COPY")
	if copy and not doc.copy_done then
		doc.copy_done = true
		doc.copy_plan(copy)
	end
end)

-- Out of the plan ([FP_OTHER_PLAN], [FP_PLANS] 4): nothing of it is kept,
-- the editor waits under the plans page, which fp:plans brings
buildat.sub_packet("fp:closed", function(data)
	local why = cereal.binary_input(data, TEXT).text
	doc.in_plan = false
	doc.joined_once = false
	doc.ents, doc.voxels, doc.voxel_version = {}, {}, {}
	doc.others, doc.privs = {}, {}
	doc.ghost_info, doc.ghost = "", nil
	doc.undo_stack, doc.redo_stack = {}, {}
	doc.suspend_editor()
	if why ~= "" then
		doc.notice(why)
	end
end)

-- Back to the plans, which is also where the next join starts
function doc.close_plan()
	buildat.storage_write("plan", "")
	buildat.send_packet("fp:leave_plan", "")
end

-- The open plan copied as `name`, which is then the one open and the
-- copier's ([FP_COPY]); the server refuses a name a plan has already
function doc.copy_plan(name)
	buildat.send_packet("fp:copy_plan", cereal.binary_output(
			{text = plan_name(name)},
			TEXT))
end

-- The name a copy is offered: the plan's own and _n, the lowest n no plan
-- has
function doc.copy_name()
	local taken = {}
	for _, p in ipairs(doc.plans or {}) do
		taken[p.name] = true
	end
	local base = doc.backup and doc.backup.of or
			doc.plan_name ~= "" and doc.plan_name or "plan"
	local n = 1
	while taken[base .. "_" .. n] do
		n = n + 1
	end
	return base .. "_" .. n
end

-- The editor is loaded once joined: it needs the document to show anything
local editor = nil
function doc.suspend_editor()
	if editor then
		editor.suspend()
	end
end
function doc.joined()
	doc.joined_once = true
	if login_window then
		login_window:Remove()
		login_window = nil
	end
	magic.ui:SetFocusElement(nil)
	if editor then
		editor.resume()
	else
		local ok, err, m = buildat.run_script_file("main/editor.lua")
		if not ok or type(m) ~= "table" then
			error("floorplanner: could not load editor.lua: " .. tostring(err))
		end
		editor = m
		doc.editor = m
		editor.start(doc)
	end
	-- Where this client was in the plan, last time: once a visit, since a
	-- snapshot can come again within one
	if not doc.view_restored then
		doc.view_restored = true
		editor.restore_view()
	end
end

-- The join first ([VANILLA_PUBLIC] 2), then the plans to pick
accounts.notice = function(text)
	doc.notice(text)
end
accounts.on_joined = function()
	doc.logged_in = true
	doc.is_local = accounts.hello["local"] == 1
end
-- The plan the launcher named, for its own user; before fp:plans
buildat.sub_packet("fp:launch", function(data)
	doc.launch_plan = cereal.binary_input(data, TEXT).text
end)
-- The plan picker menu has "My account..."; no corner button ([ACCOUNT_BUTTON])
accounts.no_account_button()
accounts.start({title = "Floor planner", env = "BUILDAT_FP"})

-- Whether a field had the focus last frame: Urho's UI takes a LineEdit's
-- focus on Esc before KeyDown gets here, so Esc in a field would otherwise
-- reach the editor as a bare Esc and open the pause menu
local was_typing = false
-- The chat opens on the frame after T: the key's own text comes after its
-- KeyDown and went into the new field, which then began with a "t"
local chat_pending = false

-- Esc before a plan has been open: back a page -- an account page to
-- where it was opened from, the picker's menu to the plans -- and from
-- the join or the plans, leaving
local function escape_without_editor()
	if accounts.page then
		accounts.back()
	elseif in_picker_menu then
		show_plans()
	else
		buildat.leave()
	end
end

magic.SubscribeToEvent("KeyDown", function(event_type, event_data)
	local key = event_data:GetInt("Key")
	if chat_input then
		if key == magic.KEY_ESCAPE then
			close_chat()
		end
		return
	end
	if doc.typing() or (key == magic.KEY_ESCAPE and was_typing) then
		was_typing = false
		if editor and editor.nudge(key, event_data:GetInt("Qualifiers") % 2 == 1) then
			return
		end
		-- Up and Down out of a menu's text field to the item next to it
		if editor and editor.menu_key(key) then
			return
		end
		-- Esc in a field drops what was typed: the panel comes back with
		-- what it had. In the join dialog, before there is an editor, it
		-- is the dialog's cancel, which is leaving.
		if key == magic.KEY_ESCAPE then
			magic.ui:SetFocusElement(nil)
			if editor then
				editor.refresh_panels()
			else
				escape_without_editor()
			end
		end
		return
	end
	if editor and doc.ui_hidden then
		-- A viewport's hidden menus come back, and the key does nothing else
		editor.show_ui()
		return
	elseif editor and editor.capture_key(key) then
		return
	elseif editor and key == editor.keys.key("chat") then
		chat_pending = true
	elseif key == magic.KEY_ESCAPE and not editor then
		escape_without_editor()
	elseif editor then
		editor.key_down(key, event_data)
	end
end)

magic.SubscribeToEvent("Update", function(event_type, event_data)
	if chat_pending then
		chat_pending = false
		open_chat("")
	end
	was_typing = doc.typing()
	redraw_messages()
	msg_text.visible = not doc.ui_hidden
	poll_picked()
	if editor then
		editor.update(event_data:GetFloat("TimeStep"))
	end
end)

-- vim: set noet ts=4 sw=4:
