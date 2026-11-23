-- Buildat: builtin/kit/client_lua/rec.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- [KIT_PLAYTEST_REC] This client's side of a builder's recorded playtest
-- (kit.cpp's rec_*, get_session). The server says "kit:rec" "1" when it
-- records this player; from then on this client sends "kit:rec"
-- {kind = "client", platform, screen, input} once and {kind = "perf", fps
-- (the median), fps5 (the 5th percentile), worst_ms, worst_at, frames}
-- every 5 s, its frames timed by the wall clock.
-- A mark: the key "mark" (F8) or the pause menu's "Mark this moment" draws
-- the window's view at once into a picture 480 wide (the frame as it was
-- seen, without the UI: Kit never reads the window, texture_png's rule),
-- then a field asks for a note: Enter (or Send) sends "kit:mark"
-- "<{note}>\n<PNG>", Escape (or Cancel) drops it.
return function(K)
local M, E, O = K.M, K.E, K.O
local magic = require("buildat/extension/urho3d")
local ui_utils = require("buildat/extension/ui_utils")
local network = require("buildat/extension/network")
local replicate = require("buildat/extension/replicate")
local log = K.log
local R = {on = false, frames = {}, t0 = nil, last = nil, worst = 0}
local MARK_W = 480

buildat.sub_packet("kit:rec", function(data)
	R.on = data == "1"
	log:info("kit: rec: " .. (R.on and "this playtest is recorded" or "not recorded"))
	if not R.on then
		return
	end
	local sc = magic.ui.scale
	buildat.send_packet("kit:rec", network.write_json({kind = "client",
		platform = buildat.get_env("BUILDAT_PAGE_HTTPS") ~= nil and "web" or "native",
		screen = {math.floor(magic.ui.root.width * sc + 0.5),
			math.floor(magic.ui.root.height * sc + 0.5)},
		input = buildat.get_env("BUILDAT_TOUCH") == "1" and "touch" or
				"keyboard/mouse"}))
end)

function M.rec_on()
	return R.on
end

-- The frames: each one's wall time, the worst one's place
magic.SubscribeToEvent("Update", function()
	if not R.on then
		return
	end
	local now = buildat.get_time_us()
	if R.last then
		local dt = (now - R.last) / 1e6
		R.frames[#R.frames + 1] = dt
		if dt > R.worst then
			R.worst = dt
			local p = M.body_pos and M.body_pos()
			R.at = p and {p.x, p.y, p.z} or nil
		end
	end
	R.last = now
	R.t0 = R.t0 or now
	local f = R.frames
	if now - R.t0 < 5000000 or #f < 2 then
		return
	end
	table.sort(f)
	local med, p95 = f[math.floor(#f / 2) + 1], f[math.min(#f, math.floor(#f * 0.95) + 1)]
	buildat.send_packet("kit:rec", network.write_json({kind = "perf",
		fps = 1 / math.max(med, 1e-4), fps5 = 1 / math.max(p95, 1e-4),
		worst_ms = R.worst * 1000, worst_at = R.at, frames = #f}))
	if not R.reported then
		R.reported = true
		log:info(string.format("kit: rec: the first perf report sent, %d frames, "
				.. "median %.1f fps", #f, 1 / math.max(med, 1e-4)))
	end
	R.frames, R.t0, R.worst, R.at = {}, now, 0, nil
end)

-- ---- The mark: the picture (as module.lua's VIEW draws the window's view
-- for get_view), then the note's field
local MK = {}

local function snap()
	local main = magic.renderer:GetViewport(0)
	local from, cam0
	if O.camera then
		if M.view_camera then
			from, cam0 = M.view_camera()
		else
			from, cam0 = O.camera, O.camera:GetComponent("Camera")
		end
	end
	local scene = O.scene or replicate.main_scene
	local sw, sh = magic.ui.root.width, magic.ui.root.height
	if not (main and from and cam0 and scene and sw > 0 and sh > 0) then
		return "this client draws no view"
	end
	local w = MARK_W
	local h = math.max(16, math.min(768, math.floor(w * sh / sw + 0.5)))
	local node = scene:CreateChild("kit: mark's camera")
	local cam = node:CreateComponent("Camera")
	cam.fov, cam.nearClip, cam.farClip = cam0.fov, cam0.nearClip, cam0.farClip
	cam.orthographic, cam.orthoSize = cam0.orthographic, cam0.orthoSize
	cam.zoom = cam0.zoom
	node.position = from.worldPosition
	node.direction = from.worldDirection
	local tex = magic.Texture2D:new()
	tex:SetNumLevels(1)
	if not tex:SetSize(w, h, magic.Graphics.GetRGBAFormat(),
			magic.TEXTURE_RENDERTARGET) then
		node:Remove()
		return "no render target of " .. w .. "x" .. h
	end
	local vp = magic.Viewport:new(scene, cam)
	vp.renderPath = main.renderPath
	local surface = tex:GetRenderSurface()
	surface:SetViewport(0, vp)
	surface.updateMode = magic.SURFACE_MANUALUPDATE
	surface:QueueUpdate()
	MK.job = {node = node, tex = tex, vp = vp, surface = surface, frames = 0}
	return nil
end

-- Read two frames after it was queued (the frame it was queued in draws it)
magic.SubscribeToEvent("Update", function()
	local j = MK.job
	if not j then
		return
	end
	j.frames = j.frames + 1
	if j.frames < 2 then
		return
	end
	MK.job = nil
	local png, why = magic.texture_png(j.tex)
	j.node:Remove()
	MK.png = png
	log:info("kit: mark: the picture taken, " .. (png and #png .. " bytes" or
			"none: " .. tostring(why)))
	if MK.send_after then
		MK.send_after = nil
		MK.send()
	end
end)

-- Sent: back to play; cancelled from the pause menu: back to it
local function close(sent)
	if not MK.w then
		return
	end
	MK.w:Remove()
	MK.w = nil
	magic.ui:SetFocusElement(nil)
	if E.menu then
		if not MK.from_menu then
			E.menu.hold(nil)
		elseif sent then
			E.menu.close()
		else
			E.menu.back()
		end
	end
	if not sent then
		MK.png, MK.send_after = nil, nil
		log:info("kit: mark: cancelled")
	end
end

local function send_mark()
	if not MK.w then
		return
	end
	local note = MK.edit and MK.edit.text or ""
	if MK.job then
		-- (Enter in the picture's two frames: it is read first)
		MK.send_after = true
		return
	end
	buildat.send_packet("kit:mark", network.write_json({note = note}) .. "\n" ..
			(MK.png or ""))
	log:info("kit: mark: sent, " .. #note .. " bytes of note, " ..
			(MK.png and #MK.png .. " bytes of picture" or "no picture"))
	ui_utils.show_notification("Marked for the agent", 2)
	MK.png = nil
	close(true)
end
MK.send = send_mark

-- The mark's start: the picture now, the field over the game
function M.rec_mark(from_menu)
	if not R.on or MK.w then
		return
	end
	MK.from_menu = from_menu and true or false
	MK.png = nil
	local why = snap()
	if why then
		log:info("kit: mark: no picture: " .. why)
	end
	if not magic.ui.root.defaultStyle then
		magic.ui.root.defaultStyle = K.STYLE
	end
	local w = magic.ui.root:CreateChild("Window")
	w:SetStyleAuto()
	w:SetName("kit mark")
	w:SetLayout(magic.LM_VERTICAL, 4, magic.IntRect(6, 6, 6, 6))
	w:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
	w.priority = 10
	w:SetFixedWidth(math.min(420, magic.ui.root.width - 16))
	MK.w = w
	ui_utils.dim_behind(w, "kit mark")
	K.text(w, "Mark this moment: a note for the game's agent")
	local e = w:CreateChild("LineEdit")
	e:SetStyleAuto()
	e:SetName("kit mark note")
	e.minHeight = 24
	e.clipBorder = magic.IntRect(4, 0, 4, 0)
	e.maxLength = 500
	MK.edit = e
	magic.SubscribeToEvent(e, "TextFinished", send_mark)
	local r = K.row(w)
	K.button(r, "Send", send_mark)
	K.button(r, "Cancel", function() close(false) end)
	if E.menu then
		E.menu.hold(function() close(false) end, w)
	end
	e:SetFocus(true)
	log:info("kit: mark: the note asked" .. (from_menu and " (from the pause menu)" or ""))
end

magic.SubscribeToEvent("KeyDown", function(_, data)
	-- Escape: the field let go of, so the app's Escape reaches the pause
	-- menu's hold (close) in this event (Kit runs before the app's
	-- handlers); with no menu it closes here
	if MK.w and data:GetInt("Key") == magic.KEY_ESCAPE then
		magic.ui:SetFocusElement(nil)
		if not E.menu then
			close(false)
		end
		return
	end
	-- (not while typing; a clicked button stays the focus)
	local f = magic.ui.focusElement
	if R.on and not MK.w and not (f ~= nil and f:GetTypeName() == "LineEdit") and
			not (E.menu and E.menu.held()) and M.key and
			M.key("mark", data:GetInt("Key")) then
		M.rec_mark(false)
	end
end)
-- For a drive: "event kit_mark" as the key
magic.SubscribeToEvent("command_seq:kit_mark", function()
	M.rec_mark(false)
end)
end
-- vim: set noet ts=4 sw=4:
