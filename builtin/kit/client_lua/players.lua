-- Buildat: builtin/kit/client_lua/players.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- [KIT_PLAYER_MODEL] The players' bodies (kit_plan.md 7c, "The humanoid
-- body"): VoxeLibre's character (kit/player_model.json, made from
-- mcl_armor_character.b3d by util/kit_player_model.lua) in the default
-- skin (kit/player_skin.png), its shirt in the player's team's colour,
-- animated here: stand, walk, mine (a dig, a swing) and the two together,
-- the head at the view's pitch, the held item on the right hand. The
-- others at their node's place 0.1 s back, between the places the server
-- sent (interpolated); this player's own where controls.lua predicts it,
-- out of first person. What the node's place does not say comes in its
-- "kit_pose" (kit.cpp set_pose(): yaw, pitch, swings, flags, held item).
--
-- simplified: one skin for all (64x32, VoxeLibre's layout), its shirt
-- found by its red; no skins uploaded, no armour, no equipment slots, no
-- run, jump or sit; one animation at a time (no blending, as Luanti's).

return function(K)
local M, P, O = K.M, K.P, K.O
local magic = require("buildat/extension/urho3d")
local network = require("buildat/extension/network")
local log = K.log

local DELAY = 0.1 -- the others drawn this far back (s)
local MODEL_H = 1.77 -- the model's height (m)

local model = network.parse_json(buildat.get_file_content(
		"kit/player_model.json") or "")
assert(type(model) == "table" and model.parts, "kit: player_model.json")
local ORDER = model.order
local now_s = function() return buildat.get_time_us() / 1e6 end

-- The skin's texture in a colour (nil: as it is), made once a colour:
-- the shirt's pixels (simplified: the default skin's red ones on the body
-- and the arms) are their brightness times the colour
local skins = {}
local function skin(color)
	local key = color or ""
	if skins[key] then
		return skins[key]
	end
	local img = magic.cache:GetResource("Image", "kit/player_skin.png")
	local tex
	if color and img then
		local w, h = img.width, img.height
		local out = magic.Image:new()
		out:SetSize(w, h, 4)
		local c = K.color(color, magic.Color(1, 1, 1))
		for y = 0, h - 1 do
			for x = 0, w - 1 do
				local p = img:GetPixel(x, y)
				if y >= h / 2 and x >= 16 and x < 56 and p.a > 0 and
						p.r > 0.24 and p.r > 1.6 * p.g and p.r > 1.6 * p.b then
					-- the red's own brightness, the colour's at its middle
					local l = math.min(1.6, p.r / 0.55)
					p = magic.Color(math.min(1, c.r * l), math.min(1, c.g * l),
							math.min(1, c.b * l), 1)
				end
				out:SetPixel(x, y, p)
			end
		end
		tex = magic.Texture2D:new()
		tex:SetNumLevels(1)
		tex:SetData(out)
	else
		tex = magic.cache:GetResource("Texture2D", "kit/player_skin.png")
	end
	tex.filterMode = magic.FILTER_NEAREST
	local mat = magic.Material:new()
	mat:SetTechnique(0, magic.cache:GetResource("Technique",
			"kit/DiffAlphaMask.xml"))
	mat:SetTexture(magic.TU_DIFFUSE, tex)
	mat:SetShaderParameter("MatSpecColor", magic.Color(0, 0, 0, 1))
	skins[key] = mat
	return mat
end

-- A body: a node a part, each part's triangles in the model's space
local function make_body(name)
	local root = O.scene:CreateChild(name)
	local b = {root = root, parts = {}, anim = "stand", frame = 0,
		speed = 0, swing_at = -1}
	for _, pn in ipairs(ORDER) do
		local def = model.parts[pn]
		local n = root:CreateChild(pn)
		b.parts[pn] = n
		if #def.tris > 0 then
			local cg = n:CreateComponent("CustomGeometry")
			cg:SetNumGeometries(1)
			cg:BeginGeometry(0, magic.TRIANGLE_LIST)
			for _, t in ipairs(def.tris) do
				local a = magic.Vector3(t[1], t[2], t[3])
				local bb = magic.Vector3(t[4], t[5], t[6])
				local c = magic.Vector3(t[7], t[8], t[9])
				local nrm = (bb - a):CrossProduct(c - a):Normalized()
				for k, v in ipairs({a, bb, c}) do
					cg:DefineVertex(v)
					cg:DefineNormal(nrm)
					cg:DefineTexCoord(magic.Vector2(t[8 + 2 * k], t[9 + 2 * k]))
				end
			end
			cg:Commit()
			cg.castShadows = true
			b[pn .. "_cg"] = cg
		end
	end
	return b
end

-- Shown or not (deep: a node's enabled is its own, its children drawn on)
local function show_body(b, on)
	if b.root.enabled ~= on then
		b.root:SetDeepEnabled(on)
	end
end

-- [KIT_FEEDBACK_EFFECTS] A hit's tint: for time s its whole body one unlit
-- colour (its effects' c:effect flash_*); every body's own material back
-- after. A material a colour, kept
local flash_mats = {}
local function flash_mat(color)
	local m = flash_mats[color]
	if not m then
		m = magic.Material:new()
		m:SetTechnique(0, magic.cache:GetResource("Technique",
				"Techniques/NoTextureUnlit.xml"))
		m:SetShaderParameter("MatDiffColor", K.color(color, magic.Color(1, 1, 1)))
		flash_mats[color] = m
	end
	return m
end

local function body_material(b, mat)
	for _, pn in ipairs(ORDER) do
		local cg = b[pn .. "_cg"]
		if cg then
			cg:SetMaterial(0, mat)
		end
	end
end

local function set_skin(b, color)
	if b.color == color and b.mat then
		return
	end
	b.color = color
	b.mat = skin(color)
	log:info("kit: player " .. b.id .. "'s body in " .. tostring(color or
			"the skin's colours"))
	body_material(b, b.mat)
end

local function quat(t, i)
	return magic.Quaternion(t[i], t[i + 1], t[i + 2], t[i + 3])
end

-- The held item on the hand: its look (hands.lua's), at Wield_Item's rest
local function set_item(b, item)
	if b.item == item then
		return
	end
	b.item = item
	log:info("kit: player " .. b.id .. " holds " .. (item ~= "" and item or
			"nothing"))
	if b.held then
		b.held:Remove()
		b.held = nil
	end
	local sheet = item ~= "" and M.item_types[item]
	if not sheet or not M.build_item_look then
		return
	end
	local def = model.parts.Wield_Item
	b.held = b.parts.Wield_Item:CreateChild("held")
	b.held.position = magic.Vector3(def.pivot[1], def.pivot[2], def.pivot[3])
	-- Along the forearm's line, out of the fist; metres under the model's
	-- units, 2.5 times first person's size
	b.held.rotation = quat(def.rot, 1) * magic.Quaternion(-90, 0, 0)
	local k = 2.5 / model.unit
	b.held.scale = magic.Vector3(k, k, k)
	M.build_item_look(b.held, sheet)
	if not b.root.enabled then
		b.held:SetDeepEnabled(false)
	end
end

-- Posed: an animation at a frame, the head pitched (degrees, down
-- positive) about its neck
local function pose(b, anim, frame, pitch)
	local fr = model.anims[anim]
	local n = #fr
	local i = math.floor(frame) % n
	local j = (i + 1) % n
	local t = frame - math.floor(frame)
	local A, B = fr[i + 1], fr[j + 1]
	for k, pn in ipairs(ORDER) do
		local a, bb = A[k], B[k]
		local pos = magic.Vector3(a[1] + (bb[1] - a[1]) * t,
				a[2] + (bb[2] - a[2]) * t, a[3] + (bb[3] - a[3]) * t)
		local rot = quat(a, 4):Slerp(quat(bb, 4), t)
		if pn == "Head" and pitch ~= 0 then
			local pv = model.parts.Head.pivot
			local pp = rot * magic.Vector3(pv[1], pv[2], pv[3]) + pos
			local rp = magic.Quaternion(pitch, 0, 0)
			rot = rp * rot
			pos = rp * (pos - pp) + pp
		end
		local node = b.parts[pn]
		node.position = pos
		node.rotation = rot
	end
end

-- A body drawn: where (its feet), its yaw and pitch, how fast it goes
-- (m/s), whether it digs or swung, the dt
local function draw_body(b, at, yaw, pitch, speed, mining, h, dt)
	b.root.position = at
	b.root.rotation = magic.Quaternion(0, yaw, 0)
	local s = model.unit * h / MODEL_H
	b.root.scale = magic.Vector3(s, s, s)
	b.speed = b.speed + (speed - b.speed) * math.min(1, dt * 10)
	local moving = b.speed > 0.5
	local anim = mining and (moving and "walk_mine" or "mine") or
			(moving and "walk" or "stand")
	if anim ~= b.anim then
		if mining and not b.mining then
			log:info("kit: player " .. b.id .. " " .. anim)
		end
		b.anim, b.frame = anim, 0
	end
	b.mining = mining
	-- The walk at its pace: VoxeLibre's 30 frames a second at a walk's 4
	local rate = model.fps
	if moving then
		rate = rate * math.max(0.5, math.min(2, b.speed / 4))
	end
	b.frame = (b.frame + dt * rate) % #model.anims[anim]
	pose(b, anim, b.frame, pitch)
end

-- The teams' colours by member (kit/team's: show.team_color, state
-- members)
local function team_colors()
	local by = {}
	for _, n in pairs(P.nodes) do
		local show = type(n.show) == "table" and n.show or {}
		if type(show.team_color) == "string" and show.team_color ~= "" then
			local v = n.node:GetVar("kit:members")
			local raw = v:IsEmpty() and "" or v:GetString()
			if raw ~= n.members_raw then
				n.members_raw = raw
				n.members = network.parse_json(raw)
			end
			for _, id in ipairs(type(n.members) == "table" and n.members or {}) do
				by[tonumber(id) or -1] = show.team_color
			end
		end
	end
	return by
end

local bodies = {} -- player id -> body
-- [KIT_SPECTATE] (below)
local SP = {on = false, target = nil, pos = nil, hint = nil, text = nil}

-- [KIT_CARRY_ATTACH] The entities on players (the node's "kit_attach":
-- "<player> <bone> <x> <y> <z>", kit.cpp attach_fx()): their looks drawn
-- at the player's body as it is drawn now, the bone's point (its pivot,
-- posed) and the offset (m) in the body's turn (the hand's: the arm's
-- too), over where the server's node has them (update_play's)
local BONES = {head = "Head", body = "Body", hand = "Wield_Item"}
local function draw_attached()
	for _, n in pairs(P.nodes) do
		local v = n.look and n.node:GetVar("kit_attach")
		local a = v and not v:IsEmpty() and v:GetString() or ""
		local pid, bone, x, y, z = a:match("^(%d+) (%S+) (%S+) (%S+) (%S+)$")
		local b = pid and bodies[tonumber(pid)]
		if a == "" and n.attach_to then
			-- Let go: where the server's node is, from the next frame
			n.attach_to, n.at = nil, nil
			log:info("kit: an entity let go of player")
		end
		if b and b.at then
			local root = b.root
			local rot = root.rotation
			local p = root.position
			local part = BONES[bone]
			if part then
				local node = b.parts[part]
				local pv = model.parts[part].pivot
				local lp = node.rotation * magic.Vector3(pv[1], pv[2], pv[3]) +
						node.position
				p = p + rot * (lp * root.scale.x)
				if bone == "hand" then
					rot = rot * node.rotation
				end
			end
			p = p + rot * magic.Vector3(tonumber(x) or 0, tonumber(y) or 0,
					tonumber(z) or 0)
			n.look.position = p
			n.look.rotation = rot * (n.look_rot or magic.Quaternion(0, 0, 0))
			if n.attach_to ~= a then
				n.attach_to = a
				log:info("kit: an entity drawn on player " .. pid .. " (" ..
						bone .. ")")
			end
		end
	end
end
local SWING = 10 / 30 -- the mine animation once (s)
local function mining_now(b, swings, dig, t)
	if swings ~= b.swings then
		if b.swings then
			b.swing_at = t
		end
		b.swings = swings
	end
	return dig or t - b.swing_at < SWING
end

function M.flash_player(id, color, time)
	local b = bodies[id]
	if b then
		b.flash_till, b.flash_color, b.flashing = now_s() + time, color, false
		log:info("kit: player " .. id .. "'s body flashes " .. tostring(color))
	end
end

-- Each frame, from controls.lua: this player's body at `own` (its feet;
-- nil: none yet), yaw and pitch, its height, whether it is shown (posed
-- all the same: what is attached to it is drawn on it); the others
function M.draw_players(own, yaw, pitch, h, show_own)
	local dt = M.frame_dt or 1 / 60
	local t = now_s()
	local teams = team_colors()
	local seen = {}
	for id, n in pairs(P.nodes) do
		local show = type(n.show) == "table" and n.show or {}
		if show.player and (id ~= P.you or own) then
			local v = n.node:GetVar("kit_pose")
			local ps = v:IsEmpty() and "" or v:GetString()
			local pyaw, ppitch, pswings, pflags, pitem =
					ps:match("^(%S+) (%S+) (%S+) (%S+) ?(.*)$")
			local flags = tonumber(pflags) or 0
			-- In a seat or out of play (waiting to respawn): not drawn
			local hidden = flags % 8 >= 2 and id ~= P.you
			local b = bodies[id]
			if not hidden then
				seen[id] = true
				if not b then
					b = make_body("kit_player")
					b.id = id
					bodies[id] = b
					b.samples = {}
					log:info("kit: player " .. id .. "'s body drawn")
				end
				b.hidden = false
				-- (one watched is seen from its eyes)
				show_body(b, (id ~= P.you or show_own == true) and
						id ~= SP.target)
				set_skin(b, teams[id])
				if b.flash_till then
					if t >= b.flash_till then
						b.flash_till = nil
						body_material(b, b.mat)
					elseif not b.flashing then
						body_material(b, flash_mat(b.flash_color))
					end
					b.flashing = b.flash_till ~= nil
				end
				local at, speed
				local item, dig, sw
				if id == P.you then
					at = magic.Vector3(own[1], own[2], own[3])
					item = select(2, M.held_item()) or ""
					dig = M.dig_progress and M.dig_progress() ~= nil
					sw = M.pose_swings or 0
					yaw = yaw or 0
				else
					-- Its place: the samples as they came, drawn DELAY back
					local p = n.node.position
					p = magic.Vector3(p.x, p.y - 0.5, p.z)
					local s = b.samples
					local last = s[#s]
					if not last or (last.p - p):Length() > 1e-4 then
						if last and t - last.t > 0.15 then
							-- After a stop: from where it stood, a tick ago
							s[#s + 1] = {t = t - 1 / 30, p = last.p}
						end
						if last and (last.p - p):Length() > 8 then
							-- A teleport: there at once
							b.samples = {}
							s = b.samples
						end
						s[#s + 1] = {t = t, p = p}
						while #s > 2 and s[2].t < t - DELAY - 0.5 do
							table.remove(s, 1)
						end
					end
					local rt = t - DELAY
					at = s[1].p
					for k = #s, 1, -1 do
						if s[k].t <= rt then
							local nx = s[k + 1]
							if nx then
								local f = (rt - s[k].t) / math.max(1e-6, nx.t - s[k].t)
								at = s[k].p + (nx.p - s[k].p) * f
							else
								at = s[k].p
							end
							break
						end
					end
					item = pitem or ""
					dig = flags % 2 == 1
					sw = tonumber(pswings) or 0
				end
				local was = b.at or at
				local d = at - was
				speed = math.sqrt(d.x * d.x + d.z * d.z) / math.max(dt, 1e-3)
				b.at = at
				local want = id == P.you and yaw or tonumber(pyaw) or 0
				-- The others' turn eased (the pose comes a tick at a time)
				if id ~= P.you and b.yaw then
					local dd = ((want - b.yaw) % 360 + 540) % 360 - 180
					want = b.yaw + dd * math.min(1, dt * 15)
				end
				b.yaw = want
				local pt = id == P.you and pitch or tonumber(ppitch) or 0
				b.pitch = pt
				set_item(b, item)
				draw_body(b, at, b.yaw, math.max(-60, math.min(60, pt or 0)), speed,
						mining_now(b, sw, dig, t), id == P.you and h or 1.7, dt)
			elseif b then
				show_body(b, false)
				b.hidden = true
			end
		end
	end
	draw_attached()
	for id, b in pairs(bodies) do
		if not seen[id] then
			if not P.nodes[id] then
				b.root:Remove()
				bodies[id] = nil
				log:info("kit: player " .. id .. "'s body gone")
			else
				show_body(b, false)
			end
		end
	end
end

-- ---- [KIT_SPECTATE] Out of play -- dead and waiting to respawn (kit/
-- health's "waiting", M.waiting()) -- this player watches: a free camera
-- (the movement keys, jump and down; from where they were) or another
-- player's view (their drawn body's eyes, their pose's look; that body
-- not drawn), the clicks cycling: the left the next, the right the one
-- before, own team first, then the others by id, then the free camera
-- again. No actions (the server refuses them). A hint of the keys at the
-- screen's bottom.

function M.spectating()
	return M.waiting ~= nil and M.waiting()
end

local function eye_of(id)
	local b = bodies[id]
	if not b or not b.at or b.hidden or not P.nodes[id] then
		return nil
	end
	local h = b.root.scale.x / model.unit * MODEL_H
	return b.at + magic.Vector3(0, h * 0.91, 0), b.yaw or 0, b.pitch or 0
end

-- Whom to watch, in order: the own team's, then the rest, by id
local function watchable()
	local teams = team_colors()
	local mine = teams[P.you]
	local list = {}
	for id, b in pairs(bodies) do
		if id ~= P.you and not b.hidden and P.nodes[id] then
			list[#list + 1] = id
		end
	end
	table.sort(list, function(a, b)
		local ta, tb = mine ~= nil and teams[a] == mine, mine ~= nil and
				teams[b] == mine
		if ta ~= tb then
			return ta
		end
		return a < b
	end)
	return list
end

local function name_of(id)
	local n = P.nodes[id]
	local show = n and type(n.show) == "table" and n.show or {}
	return tostring(show.player_name or ("player " .. id))
end

local function set_hint(text)
	if text == SP.text then
		return
	end
	SP.text = text
	if not SP.hint then
		SP.hint = magic.ui.root:CreateChild("Text")
		SP.hint:SetFont(magic.cache:GetResource("Font", buildat.font_mono), 15)
	end
	if text then
		SP.hint:SetText(text)
		log:info("kit: spectating: " .. text:gsub("\n", " | "))
	end
end

-- [KIT_HUD_STYLE] Where kit/game_rules keeps it
magic.SubscribeToEvent("Update", function()
	if SP.hint then
		SP.hint.visible = SP.text ~= nil and not M.hud_off()
	end
	if SP.hint and SP.hint.visible then
		M.own_place_text(SP.hint, "hint", 1.6)
	end
end)

-- The camera's place and turn while spectating (nil: not), from
-- controls.lua's place_camera: where it is now and the mouse's look
function M.spectate_view(dt, cam_pos, yaw, pitch)
	local on = M.spectating()
	if on ~= SP.on then
		SP.on, SP.target, SP.pos = on, nil, nil
		log:info("kit: spectating " .. (on and "on" or "off"))
		if not on then
			set_hint(nil)
		end
	end
	if not on then
		return nil
	end
	if SP.target and not eye_of(SP.target) then
		SP.target = nil
	end
	if SP.target then
		local p, y, pt = eye_of(SP.target)
		SP.pos = p
		set_hint("Watching " .. name_of(SP.target) .. "\n[Left click] next  " ..
				"[Right click] back")
		return p, magic.Quaternion(pt, y, 0)
	end
	SP.pos = SP.pos or cam_pos
	local rot = magic.Quaternion(pitch, yaw, 0)
	local v = magic.Vector3(0, 0, 0)
	local function k(id) return M.key_down and M.key_down(id) end
	if k("forward") then v = v + rot * magic.Vector3(0, 0, 1) end
	if k("back") then v = v - rot * magic.Vector3(0, 0, 1) end
	if k("right") then v = v + rot * magic.Vector3(1, 0, 0) end
	if k("left") then v = v - rot * magic.Vector3(1, 0, 0) end
	if k("jump") then v = v + magic.Vector3(0, 1, 0) end
	if k("down") then v = v - magic.Vector3(0, 1, 0) end
	if v:Length() > 0 then
		SP.pos = SP.pos + v:Normalized() * (8 * dt)
	end
	set_hint("Free camera: [" .. tostring(M.key_name("forward")) .. "][" ..
			tostring(M.key_name("left")) .. "][" .. tostring(M.key_name("back")) ..
			"][" .. tostring(M.key_name("right")) .. "] move, [" ..
			tostring(M.key_name("jump")) .. "] up, [" ..
			tostring(M.key_name("down")) .. "] down\n[Left click] watch a " ..
			"player  [Right click] back")
	return SP.pos, rot
end

-- A click while spectating: the next (left) or the one before; true:
-- taken
function M.spectate_click(left)
	if not SP.on then
		return false
	end
	local list = watchable()
	list[#list + 1] = false -- the free camera
	local at = #list
	for i, id in ipairs(list) do
		if id == SP.target then
			at = i
		end
	end
	local i = (at + (left and 1 or -1) - 1) % #list + 1
	SP.target = list[i] or nil
	log:info("kit: spectating " .. (SP.target and name_of(SP.target) or
			"with the free camera"))
	return true
end

-- [KIT_PLAYER_MODEL] This player's swings, which the others see (sent
-- with each input, controls.lua)
local view_swing = M.view_swing
function M.view_swing(...)
	M.pose_swings = (M.pose_swings or 0) + 1
	return view_swing(...)
end

magic.SubscribeToEvent("Update", function(_, data)
	M.frame_dt = data:GetFloat("TimeStep")
end)

-- The bodies, for a drive: "event kit_players" logs each drawn one, and
-- what is attached to them
magic.SubscribeToEvent("command_seq:kit_players", function()
	if SP.on and SP.pos then
		log:info(string.format("kit: the spectator's camera at %.2f,%.2f,%.2f",
				SP.pos.x, SP.pos.y, SP.pos.z))
	end
	for id, n in pairs(P.nodes) do
		if n.attach_to and n.look then
			local p = n.look.position
			log:info(string.format("kit: entity %d drawn at %.2f,%.2f,%.2f on %s",
					id, p.x, p.y, p.z, n.attach_to))
		end
	end
	for id, b in pairs(bodies) do
		if b.root.enabled then
			local p = b.root.position
			log:info(string.format("kit: player %d drawn at %.2f,%.2f,%.2f " ..
					"yaw %.0f, %s, team %s, holding %s", id, p.x, p.y, p.z,
					b.yaw or 0, b.anim, tostring(b.color), tostring(b.item)))
			if b.held then
				local h = b.held.worldPosition
				log:info(string.format("kit: player %d's %s at %.2f,%.2f,%.2f",
						id, b.item, h.x, h.y, h.z))
			end
		end
	end
end)
end
-- vim: set noet ts=4 sw=4:
