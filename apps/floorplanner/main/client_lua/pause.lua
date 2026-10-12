-- Buildat: apps/floorplanner/main/client_lua/pause.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The pause menu and its pages ([FP_EDITOR_MODULES]: out of editor.lua,
-- over its E). Puts open_pause and close_pause in E; the window is
-- E.pause_win.
return function(E)
local ANGLE_STEPS, GRID_STEPS, M, S = E.ANGLE_STEPS, E.GRID_STEPS, E.M, E.S
local geom, grid_step, keys, magic = E.geom, E.grid_step, E.keys, E.magic
local of_type, panel, refresh_panels, send = E.of_type, E.panel, E.refresh_panels, E.send
local set_view, settings, update_capture = E.set_view, E.settings, E.update_capture

-- The pause menu ([FP_ESC]): what Esc opens at the bottom of any view, and
-- a level of its own, so Esc on it is Continue. Its Settings are the
-- planner's; the engine's are the launcher's.
local open_pause, close_pause
-- For the toolbar's Menu, built before these are
M.open_pause = function() open_pause() end
do
	-- **Over the panels, and within the screen** ([FP_MENU_BEHIND]: a
	-- tester's Client settings went behind the palette, rebuilt after it
	-- or clicked, and could not be closed): over every panel and the
	-- HUD's 90, and the page in a view that scrolls where it is taller
	-- than the screen (a large UI size on a small window)
	local view, fit
	local function dialog(title)
		if E.pause_win then
			panel.discard(E.pause_win)
		end
		E.pause_win = panel.window(magic.HA_CENTER, magic.VA_CENTER, 0, 0)
		E.pause_win.priority = 95
		view = E.pause_win:CreateChild("ScrollView")
		view:SetStyleAuto()
		view.scrollBarsAutoVisible = false
		local page = view:CreateChild("UIElement")
		page:SetLayout(magic.LM_VERTICAL, 4, magic.IntRect(0, 0, 0, 0))
		page.minWidth = 300
		view.contentElement = page
		panel.label(page, title)
		fit()
		return page
	end
	-- The view the page's size, up to the screen's height less a margin;
	-- each frame, as a page fills and changes
	function fit()
		if not E.pause_win then
			return
		end
		-- Its layout's size (minHeight is only what was set)
		-- simplified: a page that shrinks in place keeps the view's
		-- height, the view stretching it; every page is built anew
		-- The panel's border: 8 (the default style's is 4 a side); a bar
		-- only where the page is larger that way
		local page, root = view.contentElement, magic.ui.root
		local wide = page.width + 8 + view.verticalScrollBar.width > root.width - 20
		local tall = page.height + 8 + (wide and
				view.horizontalScrollBar.height or 0) > root.height - 40
		local w = wide and root.width - 20 or
				page.width + 8 + (tall and view.verticalScrollBar.width or 0)
		local h = tall and root.height - 40 or
				page.height + 8 + (wide and view.horizontalScrollBar.height or 0)
		if view.width ~= w or view.height ~= h then
			view:SetScrollBarsVisible(wide, tall)
			view:SetFixedSize(w, h)
		end
	end
	E.fit_pause = fit

	-- **The plan's settings**, everyone's in it (user: out of the
	-- properties panel, which is for the selection and the tools, and a
	-- page of their own). A viewer gets the export.
	local function plan_settings_page()
		S.pause_page = "plan"
		local w = dialog("Plan settings")
		local st = settings()
		local sid = E.doc.settings().id
		local edit = E.doc.can("edit")
		local function plan_int(label, name)
			panel.field(w, label, st[name], function(t)
				local v = tonumber(t)
				if v then
					send({{op = "set", ent = {id = sid,
							ints = {[name] = math.floor(v + 0.5)}}}})
				end
			end)
		end
		-- The plan's own, which a viewer reads
		panel.view_only = not edit
		do
			-- The grid's choice shows before the plan comes back with it
			local grids = {}
			for i, g in ipairs(GRID_STEPS) do
				grids[i] = {M.grid_text(g), g}
			end
			panel.dropdown(w, "Grid (" .. keys.name("grid") .. ")", grids, grid_step(), function(g)
				send({{op = "set", ent = {id = sid, ints = {grid = g}}}})
				st.grid = g
				plan_settings_page()
			end)
			plan_int("Ceiling mm", "ceiling")
			plan_int("Plan cut mm", "cut")
			-- The trees on the horizon (PBR): their height over their
			-- distance, 15 m at 200 m being 7.5
			panel.field(w, "Treeline %", st.treeline / 10, function(t)
				local v = tonumber(t)
				if v and v >= 0 then
					send({{op = "set", ent = {id = sid,
							ints = {treeline = math.floor(v * 10 + 0.5)}}}})
				end
			end)
			-- **The site and the moment the 3D view is lit for**
			-- ([FP_DAYLIGHT]): north, with where it is now said beside it
			-- -- where the camera points in 3D, where north is on the
			-- screen in the plan view -- the latitude, the date and the
			-- hour, a time-lapse and the ground
			local dl = M.daylight
			local nr = panel.row(w)
			panel.field(nr, "North deg", st.north, function(t)
				local v = tonumber(t)
				if v then
					send({{op = "set", ent = {id = sid,
							ints = {north = math.floor(v + 0.5) % 360}}}})
				end
			end)
			local where
			if S.view == "2d" then
				where = "North is at " .. dl.north_clock(st.north) .. " o'clock"
			else
				local fx, _, fz = geom.rot(0, 0, 1, S.pitch, S.yaw, 0)
				where = "Pointing " .. dl.compass(st.north, fx, fz)
			end
			panel.label(nr, where)
			plan_int("Latitude deg", "latitude")
			-- The moment: saved, which only editing changes, or this
			-- client's own, which anyone does
			local temp = S.sun_temp ~= nil and S.sun_temp.plan == E.doc.plan_name
			panel.view_only = false
			panel.dropdown(w, "Daylight", {{"Saved", false},
					{"Temporary", true}}, temp, function(v)
				if v then
					S.sun_temp = {plan = E.doc.plan_name, day = M.plan_day(),
							minute = math.floor(M.plan_minute()),
							lapse = st.lapse, ground = st.ground, sky = st.sky}
				else
					S.sun_temp = nil
				end
				S.dirty = true
				plan_settings_page()
			end)
			panel.view_only = not edit and not temp
			local sun = M.sun()
			local function set_ints(ints)
				if temp then
					for k, v in pairs(ints) do
						S.sun_temp[k] = v
					end
					S.dirty = true
				else
					send({{op = "set", ent = {id = sid, ints = ints}}})
				end
			end
			-- A date or an hour typed in takes over from the real clock
			panel.field(w, "Date (d.m.)", dl.date_text(M.plan_day()), function(t)
				local d = dl.parse_date(t)
				if d then
					set_ints({day = d, minute = math.floor(M.plan_minute()),
							lapse = sun.lapse == -2 and 0 or sun.lapse})
				end
			end)
			local tr = panel.row(w)
			panel.field(tr, "Time (h:mm)", dl.time_text(math.floor(M.plan_minute())),
					function(t)
				local m = dl.parse_time(t)
				if m then
					set_ints({minute = m, day = M.plan_day(),
							lapse = sun.lapse < 0 and 0 or sun.lapse})
				end
			end)
			-- The time-lapse goes on from the hour and date it shows now
			-- A dropdown's choice shows before the plan comes back with it,
			-- as the grid's
			local function choose(ints)
				set_ints(ints)
				if not temp then
					for k, v in pairs(ints) do
						st[k] = v
					end
				end
				plan_settings_page()
			end
			panel.dropdown(tr, "Time-lapse", dl.LAPSES, sun.lapse, function(v)
				choose({lapse = v, minute = math.floor(M.plan_minute()),
						day = M.plan_day()})
			end)
			local gr = panel.row(w)
			panel.dropdown(gr, "Ground", dl.GROUNDS, sun.ground, function(v)
				choose({ground = v})
			end)
			panel.dropdown(gr, "Sky", dl.SKIES, sun.sky or 0, function(v)
				choose({sky = v})
			end)
			panel.view_only = not edit
			-- **The branch point** ([FP_GHOST]): the plan as it was, or
			-- another plan imported as that, drawn faded under it in 2D
			-- simplified: the plan imported is typed by its name, not
			-- picked from the plan list
			local info = E.doc.ghost_info
			panel.label(w, "Branch point: " .. (info ~= "" and info or "none"))
			if info ~= "" then
				panel.check(w, "Its ghost in 2D", st.ghost == 1, function()
					st.ghost = st.ghost == 1 and 0 or 1
					send({{op = "set", ent = {id = sid, ints = {ghost = st.ghost}}}})
					plan_settings_page()
				end)
			end
			if edit then
				panel.button(w, "Set the branch point here", function()
					E.doc.branch_point("here")
				end)
				panel.field(w, "Import the plan named", "", function(t)
					if t ~= "" then
						E.doc.branch_point("import", t)
					end
				end)
				if info ~= "" then
					panel.button(w, "Remove the branch point", function()
						E.doc.branch_point("remove")
					end)
				end
			end
			-- The pictures in the save's images/, and the ones placed, locked
			for _, file in ipairs(E.doc.images) do
				panel.button(w, "Trace over " .. file, function()
					send({{op = "create", ent = {id = E.doc.placeholder(),
							type = "image", ints = {x = math.floor(S.cx),
							z = math.floor(S.cz)}, strs = {file = file}}}})
				end)
			end
			for _, im in ipairs(of_type("image")) do
				if im.ints.locked == 1 then
					panel.button(w, "Unlock " .. im.strs.file, function()
						send({{op = "set", ent = {id = im.id,
								ints = {locked = 0}}}})
						plan_settings_page()
					end)
				end
			end
		end
		panel.view_only = false
		panel.button(w, "Back", function() open_pause() end)
	end

	-- **This client's own settings**, kept here and nobody else's
	-- **The keys** (user: a key mapping menu like vanilla's): a row per
	-- action, its key a button; pressed, the next key down binds it --
	-- Escape leaves it, Backspace puts the default back. A key bound to
	-- two actions shows red on both, and either can be the one it does.
	-- Saved at once, in this client's storage (keys.lua).
	local function keys_page()
		local w = dialog("Keys")
		panel.label(w, "Press a key's button, then the new key.")
		panel.label(w, "Escape leaves it, Backspace puts back the default.")
		local cols = panel.row(w)
		local half = math.ceil(#keys.BINDINGS / 2)
		local col = panel.column(cols)
		for i, b in ipairs(keys.BINDINGS) do
			if i == half + 1 then
				col = panel.column(cols)
			end
			local r = panel.row(col)
			panel.label(r, b.what):SetFixedWidth(230)
			if b.action then
				local bt = panel.button(r, S.binding == b.action and "Press a key..." or
						keys.name(b.action), function()
					S.binding = b.action
					S.binding_t = buildat.get_time_us()
					keys_page()
				end, S.binding == b.action, 110)
				bt:SetFixedWidth(110)
				if keys.taken(b) then
					bt:GetChild(0):SetColor(magic.Color(1.0, 0.35, 0.3))
				end
			else
				panel.label(r, b.name, magic.Color(0.7, 0.7, 0.7)):SetFixedWidth(110)
			end
		end
		local r = panel.row(w)
		panel.button(r, "Defaults", function()
			S.binding = nil
			keys.defaults()
			refresh_panels()
			keys_page()
		end)
		panel.button(r, "Back", function()
			S.binding = nil
			open_pause()
		end)
	end
	M.keys_page = keys_page

	-- **The plan's viewports** (user, 2026-10-01): each one's name, a way
	-- to it, whether it brings its date and time with it and what they
	-- are; an editor also puts it where the camera is now, or deletes it.
	-- A viewer goes to them.
	local function viewports_page()
		local w = dialog("Viewports")
		local edit = E.doc.can("edit")
		local dl = M.daylight
		local list = M.viewports()
		if #list == 0 then
			panel.label(w, "None yet: \"Save viewport\" in the view dropdown,")
			panel.label(w, "in 3D or walking, saves the camera as one")
		end
		local function set(id, ints, strs)
			send({{op = "set", ent = {id = id, ints = ints, strs = strs}}},
					function() viewports_page() end)
		end
		for _, e in ipairs(list) do
			local v = e.ints
			panel.view_only = not edit
			panel.field(w, "Name", e.strs.name, function(t)
				if t ~= "" then
					set(e.id, nil, {name = t})
				end
			end, 160, true)
			panel.view_only = false
			local r = panel.row(w)
			panel.label(r, v.walk == 1 and "Walking" or "3D")
			-- (user) The camera there, the menu left open; Go to below goes
			-- to the one previewed
			panel.keep(function() return panel.button(r, "Preview", function()
				M.previewed = e.id
				M.go_viewport(e.id, true)
				viewports_page()
			end, M.previewed == e.id) end)
			if edit then
				if S.view ~= "2d" and not S.vp then
					panel.button(r, "Use this camera", function()
						local walk = S.view == "walk"
						set(e.id, {layout = S.layout,
								x = math.floor(S.pos.x * 1000 + 0.5),
								y = math.floor(S.pos.y * 1000 + 0.5),
								z = math.floor(S.pos.z * 1000 + 0.5),
								yaw = math.floor(S.yaw % 360 * 1000 + 0.5) % 360000,
								pitch = math.floor(S.pitch * 1000 + 0.5),
								walk = walk and 1 or 0,
								fov = math.floor((walk and S.walk_fov or 60) + 0.5)})
					end)
				end
				panel.button(r, "Delete", function()
					send({{op = "delete", ent = {id = e.id}}},
							function() viewports_page() end)
				end)
			end
			panel.view_only = not edit
			panel.check(w, "Recall its date and time", v.recall == 1, function()
				set(e.id, {recall = 1 - v.recall})
			end)
			local tr = panel.row(w)
			panel.field(tr, "Date (d.m.)", dl.date_text(v.day), function(t)
				local d = dl.parse_date(t)
				if d then
					set(e.id, {day = d})
				end
			end)
			panel.field(tr, "Time (h:mm)", dl.time_text(v.minute), function(t)
				local m = dl.parse_time(t)
				if m then
					set(e.id, {minute = m})
				end
			end)
			panel.view_only = false
			panel.label(w, " ")
		end
		local br = panel.row(w)
		panel.button(br, "Back", function() open_pause() end)
		local pv = M.previewed and E.doc.ents[M.previewed]
		if pv then
			panel.keep(function() return panel.button(br, "Go to " ..
					pv.strs.name, function()
				close_pause()
				M.go_viewport(pv.id)
			end) end)
		end
	end

	-- **The client's settings window** ([GAME_SETTINGS]) with these rows as
	-- its first section; the sound, the render scale and the UI size are
	-- the window's.
	local client_settings_page
	local function client_rows(w, again)
		local angles = {}
		for i = 1, #ANGLE_STEPS do
			angles[i] = {M.angle_text(i), i}
		end
		panel.dropdown(w, "Angle (" .. keys.name("angle") .. ")", angles, S.angle, function(i)
			S.angle = i
			again()
		end)
		-- How the 3D view and walking are lit ([FP_DAYLIGHT])
		-- Lightest first
		panel.dropdown(w, "3D lighting", {{"Unlit: plain, and lighter", "unlit"},
				{"PBR: the plan's sun and sky", "pbr"},
				{"PBR + room cube maps", "pbr_cube"}}, S.lighting, function(v)
			S.lighting = v
			buildat.storage_write("lighting", v)
			set_view(S.view)
			again()
		end)
		panel.dropdown(w, "The plan's look (" .. keys.name("flat") .. ")",
				{{"Materials, lit", 0}, {"Materials, flat colours", 1},
				{"Technical: no materials", 2}}, S.plan_look, function(v)
			S.plan_look = v
			set_view(S.view)
			again()
		end)
		panel.check(w, "Material ids shown", S.show_ids, function()
			S.show_ids = not S.show_ids
			S.dirty = true
			again()
		end)
		panel.field(w, "Eye mm", S.eye, function(t)
			local v = tonumber(t)
			if v and v > 0 then
				S.eye = math.floor(v)
			end
		end)
		panel.field(w, "Walk FOV deg", S.walk_fov, function(t)
			local v = tonumber(t)
			if v then
				S.walk_fov = math.max(30, math.min(120, math.floor(v + 0.5)))
				buildat.storage_write("walk_fov", tostring(S.walk_fov))
			end
		end)
		panel.field(w, "Mouse sens. %", S.mouse_sens, function(t)
			local v = tonumber(t)
			if v then
				S.mouse_sens = math.max(10, math.min(500, math.floor(v + 0.5)))
				buildat.storage_write("mouse_sens", tostring(S.mouse_sens))
			end
		end)
		panel.field(w, "3D pan %", S.pan_speed, function(t)
			local v = tonumber(t)
			if v then
				S.pan_speed = math.max(10, math.min(1000, math.floor(v + 0.5)))
				buildat.storage_write("pan_speed", tostring(S.pan_speed))
			end
		end)
		panel.field(w, "Wheel zoom %", S.wheel_speed, function(t)
			local v = tonumber(t)
			if v then
				S.wheel_speed = math.max(10, math.min(500, math.floor(v + 0.5)))
				buildat.storage_write("wheel_speed", tostring(S.wheel_speed))
			end
		end)
		panel.check(w, "3D: the middle drag moves along the ground", S.pan_xz,
				function()
			S.pan_xz = not S.pan_xz
			buildat.storage_write("pan_xz", S.pan_xz and "1" or "0")
			again()
		end)
		panel.check(w, "3D: the wheel zooms toward the cursor", S.zoom_to_cursor,
				function()
			S.zoom_to_cursor = not S.zoom_to_cursor
			buildat.storage_write("zoom_to_cursor", S.zoom_to_cursor and "1" or "0")
			again()
		end)
	end
	client_settings_page = function()
		close_pause()
		buildat.show_game_settings{on_close = open_pause, sections = {
			{title = "Floor planner", draw = function(w, ui)
				client_rows(w, ui.redraw)
			end}}}
	end

	-- **A copy of the plan** ([FP_COPY]): under a name no plan has, which
	-- is then the plan open; the server says so if the name is taken
	local function copy_page()
		local w = dialog("Copy this plan")
		panel.label(w, (E.doc.backup and "The backup of \"" .. E.doc.backup.of ..
				"\" from " .. E.doc.backup.label or "\"" .. E.doc.plan_name .. "\"") ..
				" as:")
		local e
		local function copy()
			local n = e:GetText()
			if n ~= "" then
				close_pause()
				E.doc.copy_plan(n)
			end
		end
		e = panel.field(w, "Name", E.doc.copy_name(), copy, 180)
		local r = panel.row(w)
		panel.button(r, "Copy", copy)
		panel.button(r, "Back", function() open_pause() end)
		e:SetFocus(true)
	end

	-- **Who may use the server** ([FP_ACCESS] 4), the admin's, and a
	-- user's own password: builtin/accounts' pages, which vanilla has too.
	-- The pause menu makes way for one, and its Back brings it back.
	local function account_page(open)
		if E.pause_win then
			panel.discard(E.pause_win)
			E.pause_win = nil
		end
		open(function() open_pause() end)
	end

	-- **Who may use this plan** ([FP_PLANS] 5): its owner's and an admin's.
	-- The server sends the list when they enter it and after every change.
	local members_page
	local ROLE_CHOICES = {{"not a member", ""}, {"reader", "viewer"},
			{"editor", "editor"}}

	local function delete_plan_page()
		local w = dialog("Delete the plan " .. E.doc.plan_name .. "?")
		panel.label(w, "Everyone in it goes back to the plans.")
		local r = panel.row(w)
		panel.button(r, "Delete", function()
			close_pause()
			E.doc.plan_admin("delete")
		end)
		panel.button(r, "Back", function() members_page() end)
	end

	members_page = function()
		S.pause_page = "members"
		local w = dialog("Members of " .. E.doc.plan_name)
		local message = E.doc.admin_message or ""
		local l = panel.label(w, message ~= "" and message or " ",
				magic.Color(1.0, 0.8, 0.4))
		l.minHeight = 22
		local m = E.doc.members
		if not m then
			panel.label(w, "Waiting for the server...")
			panel.button(w, "Back", function() open_pause() end)
			return
		end
		panel.label(w, "Owner: " .. (m.owner ~= "" and m.owner or "(none)"))
		-- No "everyone" ([FP_GROUPS]): its members, and the groups its
		-- owner shares it with on the plans page's Groups
		panel.label(w, "Groups: " .. (m.groups ~= "" and m.groups or
				"none (shared under Groups on the plans page)"))
		for _, member in ipairs(m.members) do
			if member.name ~= m.owner then
				local r = panel.row(w)
				local n = panel.label(r, member.name)
				n.minWidth = 140
				panel.dropdown(r, "Role", ROLE_CHOICES, member.role, function(v)
					E.doc.plan_admin("role", member.name, v)
				end)
			end
		end
		panel.field(w, "Add a reader by name", "", function(n)
			if n ~= "" then
				E.doc.plan_admin("role", n, "viewer")
			end
		end, 140)
		panel.button(w, "Delete this plan...", delete_plan_page)
		panel.button(w, "Back", function()
			E.doc.admin_message = nil
			open_pause()
		end)
	end
	M.ghost_changed = function()
		if E.pause_win and S.pause_page == "plan" then
			plan_settings_page()
		end
	end
	M.members_changed = function()
		if E.pause_win and S.pause_page == "members" then
			members_page()
		end
	end

	-- **The plan's backups** ([FP_BACKUPS]), newest first: one opens to
	-- look at, and Copy this plan keeps it
	local function backups_page()
		S.pause_page = "backups"
		local w = dialog("Backups of " .. (E.doc.backup and E.doc.backup.of or
				E.doc.plan_name))
		local b = E.doc.backups
		if not b then
			panel.label(w, "Waiting for the server...")
		elseif #b.rows == 0 then
			panel.label(w, "None yet: one is made when the plan opens changed,")
			panel.label(w, "and each hour it is open and changes.")
		else
			panel.label(w, "Each opens view only.")
			for _, r in ipairs(b.rows) do
				local here = E.doc.backup and E.doc.plan_name:sub(-#r.id - 1) ==
						"-" .. r.id
				panel.button(w, r.label, function()
					close_pause()
					E.doc.open_backup(r.id)
				end, here)
			end
		end
		panel.button(w, "Back", function() open_pause() end)
	end
	-- Put back as the plan, after a yes: the plan as it is goes into a
	-- backup first
	local function restore_page()
		local w = dialog("Restore " .. E.doc.backup.of .. " to this backup?")
		panel.label(w, "It becomes as it was " .. E.doc.backup.label)
		panel.label(w, "for everyone in it. How it is now is kept")
		panel.label(w, "as a backup, which can be restored in turn.")
		local r = panel.row(w)
		panel.button(r, "Restore", function()
			close_pause()
			E.doc.restore_backup()
		end)
		panel.button(r, "Back", function() open_pause() end)
	end
	M.backups_changed = function()
		if E.pause_win and S.pause_page == "backups" then
			backups_page()
		end
	end

	open_pause = function()
		S.pause_page = nil
		S.paused = true
		-- A phone's address bar back with the menu, away without it
		buildat.set_web_fullscreen(false)
		S.press, S.drag = nil, nil
		update_capture()
		local version, hash = buildat.version()
		local w = dialog("Floor planner v." .. tostring(version) .. (hash and hash ~= "" and ("-" .. hash) or ""))
		-- Which plan this is, at a glance (user); a backup says so
		if E.doc.backup then
			local c = magic.Color(1.0, 0.85, 0.3)
			panel.label(w, "Backup of " .. E.doc.backup.of, c)
			panel.label(w, E.doc.backup.label, c)
			panel.label(w, "View only", c)
		else
			panel.label(w, "Plan: " .. (E.doc.plan_name or "?"),
					magic.Color(1.0, 0.85, 0.3))
		end
		S.pause_top = w
		panel.button(w, "Continue (Esc)", function() close_pause() end)
		-- Viewing or editing ([FP_VIEW_EDIT]): a plan opens for viewing, and
		-- editing goes back to it after 30 minutes without an edit
		local modes = {{"Viewing", false}}
		if E.doc.can("can_edit") then
			modes[2] = {"Editing", true}
		end
		panel.dropdown(w, "Mode", modes, E.doc.can("edit"), function(v)
			E.doc.set_editing(v)
		end)
		panel.button(w, "Plan settings...", plan_settings_page)
		panel.button(w, "Client settings...", client_settings_page)
		panel.button(w, "Keys...", keys_page)
		panel.button(w, "Viewports...", viewports_page)
		panel.button(w, "Chat...", function()
			account_page(E.doc.accounts.chat_page)
		end)
		if E.doc.privs.admin then
			panel.button(w, "Accounts...", function()
				account_page(E.doc.accounts.users_page)
			end)
		end
		if E.doc.privs.manage then
			panel.button(w, "Plan members...", function()
				E.doc.plan_admin("list")
				members_page()
			end)
		end
		if not E.doc.is_local then
			panel.button(w, "My account...", function()
				account_page(E.doc.accounts.account_page)
			end)
			-- To the Starports that list it ([STARPORT] 5); the dialog is
			-- the client's own
			panel.button(w, "Report this server...", function()
				require("buildat/extension/starport").open_report_here()
			end)
		end
		-- Anyone makes a copy, which is theirs, and goes back to the plans
		-- ([FP_PLANS] 4, 5)
		panel.button(w, "Copy this plan...", copy_page)
		panel.button(w, "Backups...", function()
			E.doc.request_backups()
			backups_page()
		end)
		if E.doc.backup and E.doc.backup.restore == 1 then
			panel.button(w, "Restore this backup...", restore_page)
		end
		if E.doc.backup then
			panel.button(w, "Back to " .. E.doc.backup.of, function()
				close_pause()
				E.doc.open_plan(E.doc.backup.of)
			end)
		end
		panel.button(w, "Export this plan", function()
			close_pause()
			E.doc.export_plan()
		end)
		panel.button(w, "Other plan...", function()
			close_pause()
			E.doc.close_plan()
		end)
		-- A browser tab has no launcher to leave to, and is closed as a tab
		-- (only the web page sets BUILDAT_PAGE_HTTPS)
		if buildat.get_env("BUILDAT_PAGE_HTTPS") == nil then
			panel.button(w, "Leave to the launcher", function() buildat.leave() end)
			panel.button(w, "Quit", function() buildat.quit() end)
		elseif not E.doc.is_local then
			-- The tab's way out, which also ends a kept login ([ACC_KEEP])
			panel.button(w, "Log out", E.doc.accounts.logout)
		end
	end

	close_pause = function()
		E.doc.accounts.close_page()
		if E.pause_win then
			panel.discard(E.pause_win)
			E.pause_win = nil
		end
		S.paused = false
		buildat.set_web_fullscreen(true)
		update_capture()
	end
	-- Whether the menu's first page is what is up
	function M.pause_top()
		return E.pause_win ~= nil and E.pause_win == S.pause_top
	end
	M.open_pause = function() open_pause() end
end

E.open_pause, E.close_pause = open_pause, close_pause
end
-- vim: set noet ts=4 sw=4:
