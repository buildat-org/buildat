-- Buildat: apps/floorplanner/main/client_lua/tutorial.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- **The tutorial** ([FP_TUTORIAL], user 2026-10-01): steps of a text and a
-- check, in a small window in a corner; the next step comes when the
-- check says the user did it. Started from the plan picker, kept on this
-- client over a reload. It only reads what the editor and the document
-- already have: nothing in the editor knows it is there.
--
--   local tutorial = run_script_file("main/tutorial.lua")(doc)
--   tutorial.start()
-- doc.editor is the editor once it is loaded; its M.S is its state.
local magic = require("buildat/extension/urho3d")

return function(doc)
	local T = {}
	local win, title, body = nil, nil, nil
	local step = tonumber(buildat.storage_read("tutorial") or "") or 0
	local mark = {} -- what a step's check compares against, from its start

	local function ed()
		return doc.editor
	end
	local function S()
		return doc.editor and doc.editor.S or {}
	end
	local function of(type)
		return doc.in_plan and doc.of_type(type) or {}
	end
	local function kind_of(inst)
		local d = doc.ents[inst.ints.def]
		return d and d.ints.kind
	end
	local function instances(kind)
		local out = {}
		for _, i in ipairs(of("instance")) do
			if kind_of(i) == kind then
				out[#out + 1] = i
			end
		end
		return out
	end
	local function lamp_entry(id)
		local e = doc.ents[id]
		return e and e.type == "palette" and e.ints.kind == 4
	end
	local function lamp_on(id)
		local lo = S().local_on
		if lo and lo[id] ~= nil then
			return lo[id]
		end
		return doc.ents[id] and doc.ents[id].ints.on == 1
	end
	local function first_switch_lamps()
		for _, sw in ipairs(instances(5)) do
			if #sw.lists.lamps > 0 then
				return sw.lists.lamps
			end
		end
		return {}
	end
	local function lamps_state()
		local t = {}
		for _, l in ipairs(first_switch_lamps()) do
			t[#t + 1] = lamp_on(l) and "1" or "0"
		end
		return table.concat(t)
	end
	-- The lowest floor
	local function ground()
		local low = nil
		for _, l in ipairs(of("layout")) do
			if not low or l.ints.y < low.ints.y then
				low = l
			end
		end
		return low and low.id
	end
	local function minute()
		return ed() and ed().plan_minute and ed().plan_minute() or 0
	end

	-- A touchscreen's words, and how its folded panels are opened: a
	-- phone folds the palette and the properties away, and a step that
	-- needs one says so while it is folded
	local touch = buildat.get_env("BUILDAT_TOUCH") == "1"
	-- **Only this setup's way** (user: the tutorial says how to do a
	-- thing with what the user has, not to confuse): a key's name as bound
	-- now (keys.lua), and " (key)" after a button's name on a desktop and
	-- nothing on a touchscreen, which has no keys
	local function k(action)
		local e = ed()
		return e and e.keys and e.keys.name(action) or "?"
	end
	local function kk(action)
		return touch and "" or " (" .. k(action) .. ")"
	end
	-- Words for a desktop only
	local function desk(t)
		return touch and "" or t
	end
	local function click(t)
		if not touch then
			return t
		end
		return (t:gsub("Click", "Tap"):gsub("click", "tap"))
	end
	local function open_panel(key, name)
		local e = ed()
		if e and e.folded and e.folded(key) then
			return " (" .. name .. " is folded away: tap " .. name ..
					" in the toolbar to open it, and again to fold it)"
		end
		return ""
	end
	local function props()
		return open_panel("props", "Properties")
	end
	local function palette()
		return open_panel("palette", "Palette")
	end

	-- {text, check, enter}: the text, or a function giving it, says what
	-- to do and where it is
	local STEPS = {
		{"Welcome. This tutorial builds a small house step by step.\n" ..
				"- Type a name for a new plan in the field\n" ..
				"- Press \"New plan\"",
				function() return doc.in_plan end},
		{"A plan opens for viewing, so nothing changes by accident.\n" ..
				"- Press \"Start editing\" at the end of the toolbar",
				function() return doc.can("edit") end},
		{function() return "Go to the plan view:\n- Choose \"2D\"" .. kk("view_2d") ..
				" in the view dropdown at the left of the toolbar" end,
				function() return S().view == "2d" end},
		{function() return click("Draw a room:\n- Pick \"Room\"" .. kk("room") ..
				" in the toolbar\n- Click its corners on the floor\n" ..
				"- Click the first corner again" .. desk(", or press Enter,") ..
				" to close it\nThe room gets walls and a lamp on its ceiling. " ..
				(touch and "\"Undo\" and \"Redo\" in the bar" or
				"Ctrl+Z undoes and Ctrl+Y redoes") ..
				" a step at a time.") end,
				function() return #of("room") >= 1 end},
		{function() return click("Draw a second room beside the first:\n" ..
				"- Start and end it on the first room's corners, so the two " ..
				"share a wall") end,
				function()
					local rooms = of("room")
					for i = 1, #rooms do
						for j = i + 1, #rooms do
							local set, n = {}, 0
							for _, x in ipairs(rooms[i].lists.nodes) do
								set[x] = true
							end
							for _, x in ipairs(rooms[j].lists.nodes) do
								if set[x] then n = n + 1 end
							end
							if n >= 2 then
								return true
							end
						end
					end
					return false
				end},
		{function() return click("A door in the wall between the rooms:\n" ..
				"- Pick \"Wall items\"" .. kk("hosted") .. "\n" ..
				"- Check that \"Kind\" in its panel says \"Door\"\n" ..
				"- Click on the wall") .. props() end,
				function() return #instances(3) >= 1 end},
		{function() return click("A window, with \"Wall items\" still picked:\n" ..
				"- Set \"Kind\" to \"Window\" in the panel\n" ..
				"- Click an outside wall") .. props() end,
				function() return #instances(4) >= 1 end},
		{function() return click("A linked clone shares its shape with the original:\n" ..
				"- Pick \"Select\"" .. kk("select") .. "\n" ..
				"- Click the window\n" ..
				"- Press \"Linked clone\" in its panel" .. desk(" (Ctrl+L)") .. "\n" ..
				"- Click another wall") .. props() end,
				function()
					local n = {}
					for _, w in ipairs(instances(4)) do
						n[w.ints.def] = (n[w.ints.def] or 0) + 1
						if n[w.ints.def] >= 2 then
							return true
						end
					end
					return false
				end},
		{function() return click("A dresser:\n- Pick \"Object\"" .. kk("box") .. "\n" ..
				"- Drag its footprint on the floor against a wall, about 1 m " ..
				"by 0.5 m\n" ..
				"- Type a height of 800 in the panel's \"Height mm\"") ..
				props() end,
				function()
					for _, i in ipairs(instances(0)) do
						local h = doc.ents[i.ints.def].ints.h
						if h >= 500 and h <= 1500 and h ~= 750 then
							return true
						end
					end
					return false
				end},
		{function() return click("Build the lamp from voxels on the dresser:\n" ..
				"- Click the \"Lamp\" entry in the palette (the ceiling " ..
				"lamps made it)\n" ..
				"- Pick \"Voxels\"" .. kk("voxel") .. "\n" ..
				"- Choose \"3D\" in the view dropdown" .. kk("view_3d") .. "\n" ..
				"- Click the dresser's top to start a volume there\n" ..
				"- Click on its voxels for more\n" ..
				"The panel's \"Click\" says whether a click places, digs or " ..
				"paints.") .. palette() .. props() end,
				function()
					for _, i in ipairs(instances(1)) do
						for _, m in pairs(doc.voxels[i.ints.def] or {}) do
							if lamp_entry(m) then return true end
						end
					end
					return false
				end},
		{function() return click("A switch for it:\n- Choose \"2D\"" .. kk("view_2d") .. "\n" ..
				"- Pick \"Wall items\"" .. kk("hosted") .. "\n" ..
				"- Set \"Kind\" to \"Switch\" and click a wall\n" ..
				"- Click the switch to select it\n" ..
				"- Press \"Link lamps\" in its panel\n" ..
				"- Click the lamp and press \"Done linking\"") .. props() end,
				function()
					for _, sw in ipairs(instances(5)) do
						if #sw.lists.lamps > 0 then return true end
					end
					return false
				end},
		{function() return click("Stairs:\n" ..
				"- Click the \"drywall\" entry in the palette (what is made " ..
				"gets the entry chosen)\n" ..
				"- Pick \"Object\"" .. kk("box") .. "\n" ..
				"- Set \"Shape\" to \"stairs\" in its panel\n" ..
				"- Drag their footprint in a room\n" ..
				"They climb along their depth.") .. props() end,
				function() return #instances(6) >= 1 end},
		{"A floor above:\n" ..
				"- Press the floor's button in the toolbar (it says its name)\n" ..
				"- Press \"Add a floor above\"\n" ..
				"The new floor is edited now, the one below drawn under it.",
				function() return #of("layout") >= 2 end},
		{function() return click("- Draw a room on the new floor with \"Room\", over the " ..
				"one below\nIn the plan view (\"2D\"" ..
				desk(", " .. k("view_2d")) .. ") the floor below shows " ..
				"faintly under it to line up with.") end,
				function()
					local cur = S().layout
					for _, r in ipairs(of("room")) do
						local n = doc.ents[r.lists.nodes[1]]
						if n and n.ints.layout == cur and cur ~= ground() then
							return true
						end
					end
					return false
				end},
		{"Back to the ground floor:\n" ..
				"- Press the floor's button\n" ..
				"- Choose the first one in the list",
				function() return S().layout == ground() end},
		{function() return touch and "Walk in the house:\n- Choose \"Walk\" in the " ..
				"view dropdown\nA finger at the lower left walks, another " ..
				"turns the view." or "Walk in the house:\n- Choose \"Walk\"" ..
				kk("view_walk") .. " in the view dropdown\n" .. k("forward") ..
				", " .. k("left") .. ", " .. k("back") .. " and " .. k("right") ..
				" walk; drag with the right mouse button to turn." end,
				function() return S().view == "walk" end},
		{function() return touch and "Open the door:\n- Walk to it and tap it" or
				"Open the door:\n- Point at it and press " .. k("use") ..
				" (or right click it)"
				end,
				function()
					for _, d in ipairs(instances(3)) do
						local lo = S().local_open and S().local_open[d.id]
						if (lo or d.ints.open) > 0 then return true end
					end
					return false
				end},
		{function() return touch and "Switch the lamp:\n- Tap the switch on the " ..
				"wall" or "Switch the lamp:\n- Point at the switch and press " ..
				k("use") end,
				function() return lamps_state() ~= mark.lamps end,
				function() mark.lamps = lamps_state() end},
		{function() return click("The light is the plan's place and moment:\n" ..
				"- Switch the lamp on again if it is off\n" ..
				"- Open \"Menu\", \"Plan settings\"\n" ..
				"- Type an evening time such as 22:00 in \"Time\"\n" ..
				"- Look at the room in 3D") end,
				function() return math.abs(minute() - mark.minute) >= 60 end,
				function() mark.minute = minute() end},
		{"- In \"Menu\", \"Client settings\", set \"3D lighting\" to " ..
				"\"Unlit\", the plain look that is lighter to draw",
				function() return S().lighting == "unlit" end},
		{"- And back to \"PBR\" in the same place",
				function() return S().lighting ~= "unlit" end},
		{"- In \"Menu\", \"Plan settings\", set \"Time-lapse\" to " ..
				"\"1 h/s\"\n- Watch the day go round in 3D; \"off\" stops it\n" ..
				"\"Daylight: Temporary\" changes only your own view, which " ..
				"anyone may do.",
				function()
					local st = doc.settings and doc.settings()
					local t = S().sun_temp
					return (st and st.ints.lapse ~= 0) or (t and t.lapse ~= 0)
				end},
		{"That is the basics. Backups, members, copying and exporting are " ..
				"in \"Menu\".\n- Press \"End\" to close this",
				function() return false end},
	}

	local function text_of(i)
		local t = STEPS[i][1]
		if type(t) == "function" then
			local ok, v = pcall(t)
			return ok and v or ""
		end
		return t
	end
	-- For apps/floorplanner/test/tutorial_text.lua
	T.text_of, T.steps = text_of, #STEPS

	-- **The window** (user, a phone): small, in a corner, folded to its
	-- title by a tap on it, and under the panels and menus until it is
	-- itself tapped. A new step unfolds it.
	local folded = false
	local LOW, HIGH = -5, 99 -- under the panels (0); over the hint line (90)
	local shown_text = nil
	local function place()
		if not win then
			return
		end
		-- Lower right, over the hint lines at the bottom (four at most) and
		-- a touchscreen's buttons under them (user)
		local bar = S().touch_bar
		local y = (bar and bar.height + 20 or 12) + 4 * 20 + 8
		win:SetAlignment(magic.HA_RIGHT, magic.VA_BOTTOM)
		win:SetPosition(-4, -y)
	end
	local function show()
		if win then
			win:Remove()
			win = nil
		end
		if step < 1 or step > #STEPS then
			return
		end
		local font = magic.cache:GetResource("Font", buildat.font_sans)
		local size = touch and 12 or 14
		win = magic.ui.root:CreateChild("Window")
		if ed() then
			ed().panel.track(win)
		end
		win:SetStyleAuto()
		win:SetLayout(magic.LM_VERTICAL, 4, magic.IntRect(8, 6, 8, 6))
		local width = math.min(touch and 260 or 420, magic.ui.root.width - 16)
		win:SetFixedWidth(width)
		win.priority = LOW
		win.opacity = 0.94
		place()
		local head = win:CreateChild("Button")
		head:SetStyleAuto()
		head.minHeight = 22
		title = head:CreateChild("Text")
		title:SetFont(font, size)
		title:SetText("Tutorial " .. step .. "/" .. #STEPS ..
				(folded and "  ▼" or "  ▲"))
		title:SetColor(magic.Color(1.0, 0.85, 0.3))
		title:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
		magic.SubscribeToEvent(head, "Released", function()
			folded = not folded
			show()
			win.priority = HIGH
		end)
		body = nil
		shown_text = nil
		if folded then
			return
		end
		body = win:CreateChild("Text")
		body:SetFont(font, size)
		body:SetFixedWidth(width - 36)
		body:SetWordwrap(true)
		shown_text = text_of(step)
		body:SetText(shown_text)
		local row = win:CreateChild("UIElement")
		row:SetLayout(magic.LM_HORIZONTAL, 4, magic.IntRect(0, 0, 0, 0))
		local function button(text, fn)
			local b = row:CreateChild("Button")
			b:SetStyleAuto()
			b.minHeight = 22
			local t = b:CreateChild("Text")
			t:SetFont(font, size)
			t:SetText(text)
			t:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
			b.minWidth = t.width + 14
			magic.SubscribeToEvent(b, "Released", fn)
		end
		if step < #STEPS then
			button("Skip", function() T.go(step + 1) end)
		end
		if step > 1 then
			button("Back", function() T.go(step - 1) end)
		end
		button("End", function() T.go(0) end)
	end

	-- A press on the window brings it over the menus; one elsewhere puts
	-- it back under them
	local function pressed_at(x, y)
		if not win then
			return
		end
		local sc = magic.ui.scale
		local ux, uy = x / sc, y / sc
		local p, sz = win.screenPosition, win.size
		local on = ux >= p.x and uy >= p.y and ux < p.x + sz.x and
				uy < p.y + sz.y
		win.priority = on and HIGH or LOW
	end
	magic.SubscribeToEvent("MouseButtonDown", function()
		local m = magic.input:GetMousePosition()
		pressed_at(m.x, m.y)
	end)
	magic.SubscribeToEvent("TouchBegin", function(_, data)
		pressed_at(data:GetInt("X"), data:GetInt("Y"))
	end)

	function T.go(i)
		step = i
		buildat.storage_write("tutorial", tostring(i))
		mark = {}
		folded = false
		if STEPS[i] and STEPS[i][3] then
			STEPS[i][3]()
		end
		show()
	end

	function T.start()
		T.go(1)
	end

	-- The checks, a few times a second
	local since = 0
	magic.SubscribeToEvent("Update", function(_, data)
		if step < 1 or step > #STEPS then
			return
		end
		-- Hidden with the menus while a viewport is shown clean
		if win then
			win.visible = not doc.ui_hidden
		end
		since = since + data:GetFloat("TimeStep")
		if since < 0.25 then
			return
		end
		since = 0
		if not win then
			T.go(step)
		end
		-- The text follows what is on the screen (a folded panel), and the
		-- window the toolbar's height
		place()
		if body then
			local t = text_of(step)
			if t ~= shown_text then
				-- Made again, so that it is as high as its text
				local pr = win.priority
				show()
				win.priority = pr
			end
		end
		local ok, done = pcall(STEPS[step][2])
		if ok and done then
			T.go(step + 1)
		end
	end)

	-- A step's own marks start where it is on a reload too
	if step >= 1 and step <= #STEPS then
		T.go(step)
	end
	return T
end
-- vim: set noet ts=4 sw=4:
