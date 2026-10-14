-- Buildat: builtin/luanti/client_lua/scan.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- `event scan <resolution> <label>` in a command sequence ([SCAN_EVENT]):
-- what is on the screen, in the log under the label -- the crosshair's
-- hit, a grid of rays to ten voxels with what each hit and passed
-- through, and every element of an open form or the chat line. A run
-- reads it beside the screenshot it took in the same line. Here rather
-- than in the module's client half because the camera, the crosshair
-- march and the node names are the launcher's until the fold; init.lua
-- hands them in as ctx, as functions where the value moves.
local magic = require("buildat/extension/urho3d")
local voxelworld = require("buildat/module/voxelworld")
local luanti = require("buildat/module/luanti")

local RANGE = 10
local STEP = 0.25

return function(ctx)
	local log = ctx.log

	-- The rectangles and the UI walk are ui_utils' ([FIRST_RUN]: the menus
	-- give the same lines)
	local ui_utils = require("buildat/extension/ui_utils")
	local pixels, ui = ui_utils.scan_pixels, ui_utils.scan_ui

	local function ray(p0, dir)
		local last = nil
		local through = {}
		for i = 1, math.floor(RANGE / STEP) do
			local p = (p0 + dir * (i * STEP)):Round()
			if p ~= last then
				local v = voxelworld.get_static_voxel(p)
				if ctx.voxel_is_solid(v) then
					return ctx.node_name_at(p) or "?", p, i * STEP, through
				end
				-- Not solid but not air either: a plant, a liquid, a
				-- cutout, which the ray went through
				if v ~= nil then
					local name = ctx.node_name_at(p)
					if name and name ~= "air" then
						through[#through + 1] = name
					end
				end
				last = p
			end
		end
		return nil, nil, nil, through
	end

	-- `event scan_volume <radius> <label>`: the voxels around the player,
	-- a cube of that radius about the feet, as a name table and one line
	-- per (y, z) row of x. A driver keeps a map of them and picks which
	-- to dig and which to keep (user, 2026-09-20), which the rays of
	-- `scan` cannot give it; its own event, since a scan every turn does
	-- not need the cube every turn. 0 is air or anything not there.
	-- A third word `light` adds a `light` row per (y, z): the sky nibble
	-- the client holds for each voxel, `-` where none is loaded
	-- ([DIG_LIGHT]: what the mesher lights the faces by, beside the
	-- server's own reading).
	-- `event look_body`: the view turned to the nearest fallen body's
	-- centre ([BODY_INTERACT]'s runs: where a body lands is physics')
	magic.SubscribeToEvent("command_seq:look_body", function(event_type, event_data)
		local px, py, pz = ctx.player_pos()
		local best, best_d = nil, nil
		for _, b in ipairs(luanti.bodies()) do
			local d = (b.x - px) ^ 2 + (b.y - py) ^ 2 + (b.z - pz) ^ 2
			if best_d == nil or d < best_d then
				best, best_d = b, d
			end
		end
		if best then
			ctx.look_at(best.x, best.y, best.z)
			log:info(string.format("look_body: at %.1f, %.1f, %.1f", best.x, best.y, best.z))
		else
			log:info("look_body: no body")
		end
	end)

	magic.SubscribeToEvent("command_seq:scan_volume", function(event_type, event_data)
		local param = event_data:GetString("Param") or ""
		local r, label, extra = param:match("^(%d+)%s*(%S*)%s*(%S*)")
		-- "light" adds the sky light's lines, "lamp" the lamp light's
		local with_light = extra == "light" or extra == "lamp"
		local light_of = extra == "lamp" and "light_lamp_of" or "light_sky_of"
		r = math.max(1, math.min(8, tonumber(r) or 4))
		if label == nil or label == "" then
			label = "volume"
		end
		local px, py, pz = ctx.player_pos()
		local fx0 = math.floor(px + 0.5)
		local fy0 = math.floor(py + 0.5)
		local fz0 = math.floor(pz + 0.5)
		local names, index = {}, {}
		local lines = {}
		local reg = voxelworld.get_voxel_registry()
		for y = fy0 - r, fy0 + r do
			for z = fz0 - r, fz0 + r do
				local row, lrow = {}, {}
				for x = fx0 - r, fx0 + r do
					local v = voxelworld.get_static_voxel(buildat.Vector3(x, y, z))
					local name = v ~= nil and ctx.node_name_at(buildat.Vector3(x, y, z)) or nil
					lrow[#lrow + 1] = v ~= nil and tostring(reg[light_of](reg, v)) or "-"
					local i = 0
					if name ~= nil and name ~= "air" then
						i = index[name]
						if i == nil then
							names[#names + 1] = name
							i = #names
							index[name] = i
						end
					end
					row[#row + 1] = tostring(i)
				end
				lines[#lines + 1] = string.format("scan %s: voxels y=%d z=%d x=%d: %s",
						label, y, z, fx0 - r, table.concat(row, " "))
				if with_light then
					lines[#lines + 1] = string.format("scan %s: light y=%d z=%d x=%d: %s",
							label, y, z, fx0 - r, table.concat(lrow, " "))
				end
			end
		end
		local legend = {}
		for i, name in ipairs(names) do
			legend[i] = i .. "=" .. name
		end
		table.insert(lines, 1, string.format("scan %s: voxel names %s", label,
				table.concat(legend, " ")))
		lines[#lines + 1] = string.format("scan %s: done, %d lines", label, #lines)
		log:info(table.concat(lines, "\n"))
	end)

	-- The menu's scan (client/extensions/uistack) stands aside from here on
	require("buildat/extension/uistack").set_world_scan(true)
	magic.SubscribeToEvent("command_seq:scan", function(event_type, event_data)
		local param = event_data:GetString("Param") or ""
		local res, label = param:match("^(%d+)%s*(%S*)")
		res = math.max(1, math.min(32, tonumber(res) or 8))
		if label == nil or label == "" then
			label = "scan"
		end
		local lines = {}
		-- The player: where, which way, what is held ([SCAN_DRIVE] reads
		-- this line first). hp is the health bar's below.
		local px, py, pz = ctx.player_pos()
		local yaw0, pitch0, fov0 = ctx.view()
		local stacks = ctx.hotbar()
		-- A stack as its name and count: the wear and the metadata of an
		-- itemstring are not a reader's, and a tool's carries its
		-- translated description, escapes and all -- VoxeLibre's wooden
		-- pickaxe made every self line after its craft unreadable
		-- ([DRIVE_CYCLE], seed 4, 2026-10-04)
		local function short(stack)
			return ((tostring(stack or ""):match("^%S+ ?%d*") or ""):gsub(" $", ""))
		end
		local hot = {}
		for i = 1, math.min(#stacks, luanti.hotbar.count or 9) do
			hot[#hot + 1] = i .. ":" .. short(stacks[i])
		end
		lines[#lines + 1] = string.format(
				"scan %s: self at %.1f,%.1f,%.1f yaw %.1f pitch %.1f fov %.1f hp ? wield %s hotbar %s",
				label, px, py, pz, yaw0, pitch0, fov0,
				buildat.dump(short(ctx.wield())), table.concat(hot, " | "))
		-- The key bindings as they stand, action=key, the rebound ones
		-- marked ([KEY_BINDINGS])
		local keys = {}
		for _, b in ipairs(ctx.keys()) do
			if b.default_key ~= nil then
				keys[#keys + 1] = b.action .. "=" .. b.name ..
						(b.key ~= b.default_key and "*" or "")
			end
		end
		lines[#lines + 1] = "scan " .. label .. ": keys " .. table.concat(keys, " ")
		-- The frame the rectangles are in, and the UI root it is read off
		local lw, lh = buildat.logical_size()
		lines[#lines + 1] = string.format("scan %s: frame %dx%d root %dx%d ui_scale %.3f",
				label, lw, lh, magic.ui.root.width, magic.ui.root.height,
				magic.ui:GetScale() or 0)
		-- The light where the player stands, the eye voxel's two nibbles
		-- (0..15): what says it is dark enough for a torch ([DRIVE_STORY]
		-- rung 5)
		local ev = voxelworld.get_static_voxel(buildat.Vector3(
				math.floor(px + 0.5), math.floor(py + 1.5 + 0.5), math.floor(pz + 0.5)))
		if ev ~= nil then
			local reg = voxelworld.get_voxel_registry()
			lines[#lines + 1] = string.format("scan %s: light sky %d lamp %d", label,
					reg:light_sky_of(ev), reg:light_lamp_of(ev))
		end
		-- The HUD's bars: health, hunger, breath, armour, by their picture
		for _, e in pairs(luanti.hud_elements) do
			if e.type == "statbar" then
				local rect = ""
				local rx, ry, rw, rh = ctx.hud_rect(e)
				if rx then
					rx, ry, rw, rh = pixels(rx, ry, rw, rh)
					rect = string.format(" at %d,%d size %dx%d", rx, ry, rw, rh)
				end
				lines[#lines + 1] = string.format("scan %s: hud statbar %s %s/%s%s",
						label, buildat.dump(e.text or ""), tostring(e.number or 0),
						tostring(e.item or e.number or 0), rect)
			elseif e.type == "text" then
				-- What a game's own HUD text was drawn as, which is how a
				-- driven run reads its size ([UI_PARITY]: size.X multiplies
				-- the font, hudtext.sh)
				local rect = ""
				local rx, ry, rw, rh = ctx.hud_rect(e)
				if rx then
					rx, ry, rw, rh = pixels(rx, ry, rw, rh)
					rect = string.format(" at %d,%d size %dx%d", rx, ry, rw, rh)
				end
				lines[#lines + 1] = string.format(
						"scan %s: hud text %s size %s%s", label,
						buildat.dump(e.text or ""),
						buildat.dump(e.size or ""), rect)
			end
		end
		-- The crosshair, by the same march the dig uses; a fallen body's
		-- voxel says so, with its region position ([BODY_INTERACT])
		local hit = ctx.pointed()
		if hit and hit.y >= luanti.REGION_Y then
			local w = luanti.body_world(hit)
			lines[#lines + 1] = string.format(
					"scan %s: crosshair body voxel %s at %d,%d,%d (world %.1f,%.1f,%.1f)",
					label, ctx.node_name_at(hit) or "?", hit.x, hit.y, hit.z,
					w and w.x or 0, w and w.y or 0, w and w.z or 0)
		elseif hit then
			lines[#lines + 1] = string.format("scan %s: crosshair %s at %d,%d,%d",
					label, ctx.node_name_at(hit) or "?", hit.x, hit.y, hit.z)
		else
			lines[#lines + 1] = string.format(
					"scan %s: crosshair nothing within %d", label, ctx.dig_range())
		end
		-- The grid: a ray from the centre of each bin, built from the
		-- camera's yaw and pitch (Urho's, pitch positive down) and its
		-- field of view
		local p0 = buildat.Vector3(ctx.camera_node().worldPosition)
		local yaw, pitch, fov = ctx.view()
		local yr, pr = math.rad(yaw), math.rad(pitch)
		local fwd = buildat.Vector3(math.sin(yr) * math.cos(pr), -math.sin(pr),
				math.cos(yr) * math.cos(pr))
		local right = buildat.Vector3(math.cos(yr), 0, -math.sin(yr))
		local up = buildat.Vector3(math.sin(yr) * math.sin(pr), math.cos(pr),
				math.cos(yr) * math.sin(pr))
		local tan_v = math.tan(math.rad(fov) / 2)
		local aspect = magic.ui.root.width / math.max(1, magic.ui.root.height)
		for by = 0, res - 1 do
			for bx = 0, res - 1 do
				local sx = ((bx + 0.5) / res * 2 - 1) * tan_v * aspect
				local sy = (1 - (by + 0.5) / res * 2) * tan_v
				local dir = fwd + right * sx + up * sy
				local name, p, d, through = ray(p0, dir)
				local via = #through > 0 and
						(" via " .. table.concat(through, ",")) or ""
				-- The bins are voxels only; the objects are the listing
				-- below, every one on the screen
				if name then
					lines[#lines + 1] = string.format(
							"scan %s: bin %d,%d: %s at %d,%d,%d d=%.1f%s",
							label, bx, by, name, p.x, p.y, p.z, d, via)
				else
					lines[#lines + 1] = string.format("scan %s: bin %d,%d: %s%s",
							label, bx, by, dir.y > 0.2 and "sky" or "nothing", via)
				end
			end
		end
		-- Every object on the screen, by projection: a bin's ray misses
		-- an item lying about most of the time (a bin is ten degrees
		-- wide, an item four at four nodes), and this does not. The
		-- screen position is in window pixels, the bin the one its
		-- centre falls in.
		local ww, wh = buildat.logical_size()
		local function dot(a, b)
			return a.x * b.x + a.y * b.y + a.z * b.z
		end
		-- The player's own object while it is drawn (the third-person
		-- views): where its model stands and which way it faces, against
		-- the player's own feet and look ([BOX_PLAYTEST_4] 4, 5)
		local own = luanti.self_object()
		if own then
			local fx, fy, fz = ctx.player_pos()
			lines[#lines + 1] = string.format(
					"scan %s: self model at %.2f,%.2f,%.2f yaw %.1f;"..
					" feet %.2f,%.2f,%.2f look %.1f", label,
					own.x, own.y, own.z, own.yaw, fx, fy, fz, (ctx.view()))
			-- What rides it, in the model's own frame: right, up, ahead
			-- of where the model stands, which stays put as the player
			-- walks and turns if it is drawn with the player
			-- ([WIELD_AT_FEET])
			local yr = math.rad(own.yaw)
			for _, r in ipairs(luanti.riders()) do
				local rx, rz = r.x - own.x, r.z - own.z
				lines[#lines + 1] = string.format(
						"scan %s: rider %s right %.2f up %.2f ahead %.2f",
						label, r.id, rx * math.cos(yr) - rz * math.sin(yr),
						r.y - own.y, rx * math.sin(yr) + rz * math.cos(yr))
			end
			-- And where the camera ended up, which is what says whether a
			-- third-person view was pulled in by a wall behind the player
			-- or is drawing at its own distance ([OVER_SHOULDER])
			local dx, dy, dz = p0.x - fx, p0.y - fy, p0.z - fz
			local _, _, cam_fov = ctx.view()
			lines[#lines + 1] = string.format(
					"scan %s: camera at %.2f,%.2f,%.2f, %.2f nodes from the"..
					" feet, fov %.1f", label, p0.x, p0.y, p0.z,
					math.sqrt(dx * dx + dy * dy + dz * dz), cam_fov)
		end
		-- The objects, and the fallen bodies as objects with them: a body
		-- is listed by its node id and its centre, so the driver can walk
		-- to one and point at it
		local listed = luanti.objects()
		for _, b in ipairs(luanti.bodies()) do
			listed[#listed + 1] = {id = "body" .. b.id, label = "voxel body",
					x = b.x, y = b.y, z = b.z}
		end
		for _, o in ipairs(listed) do
			local d = buildat.Vector3(o.x, o.y, o.z) - p0
			local depth = dot(d, fwd)
			if depth > 0.1 and depth <= RANGE then
				local sx = dot(d, right) / depth / (tan_v * aspect)
				local sy = dot(d, up) / depth / tan_v
				if sx >= -1 and sx <= 1 and sy >= -1 and sy <= 1 then
					lines[#lines + 1] = string.format(
							"scan %s: object %s %s at %.1f,%.1f,%.1f d=%.1f screen %d,%d bin %d,%d",
							label, tostring(o.id), o.label, o.x, o.y, o.z,
							d:Length(), math.floor((sx + 1) / 2 * ww),
							math.floor((1 - sy) / 2 * wh),
							math.min(res - 1, math.floor((sx + 1) / 2 * res)),
							math.min(res - 1, math.floor((1 - sy) / 2 * res)))
				end
			end
		end
		-- What takes input, if anything: the form (the inventory, the
		-- pause menu and the death screen are forms too) or the chat line
		local formname, window = luanti.form_window()
		local chat = ctx.chat_text()
		if window then
			lines[#lines + 1] = string.format("scan %s: form %s open", label,
					buildat.dump(formname))
			-- The slots by list and index, with what is in them: the
			-- elements below are the pictures and do not say
			for _, s in ipairs(luanti.form_slots() or {}) do
				local x, y, w, h = pixels(s.x, s.y, s.size, s.size)
				lines[#lines + 1] = string.format(
						"scan %s: slot %s:%s:%d at %d,%d size %dx%d item %s", label,
						s.location, s.list, s.index, x, y, w, h,
						buildat.dump(s.stack))
			end
			ui(label, window, 1, lines)
		elseif chat then
			lines[#lines + 1] = string.format("scan %s: chat line open, text %s",
					label, buildat.dump(chat))
		else
			lines[#lines + 1] = string.format("scan %s: no form open", label)
		end
		-- A menu screen left over the world ([WIN_WORLD] (b): a box kept
		-- "Building the world" up after the join); the driver fails on it.
		-- An app's world menu is "<app> menu: <what>" (vanilla's menu.lua)
		local stack = require("buildat/extension/uistack").main.stack
		local top = stack[#stack]
		if top and top:GetName():find(" menu: ", 1, true) then
			lines[#lines + 1] = string.format("scan %s: menu screen %s over the world",
					label, buildat.dump(top:GetName()))
		end
		lines[#lines + 1] = string.format("scan %s: done, %d lines", label, #lines)
		log:info(table.concat(lines, "\n"))
	end)
end
-- vim: set noet ts=4 sw=4:
