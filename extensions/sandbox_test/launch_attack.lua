-- [LAUNCH_SANDBOX]'s conformance test: **a deliberately hostile launch
-- UI**. The launch UI is a slot anybody can fill, so the question this
-- answers is the only one that matters about it -- can what fills it
-- reach past the verbs? Every attempt below is a thing a launch UI
-- might genuinely want, done the way a hostile one would do it.
--
-- Run inside the sandbox by sandbox_test's own boot(), which is how a
-- launch UI runs. Each attempt is expected to be refused; the verdict
-- line is what a check reads, and it names anything that got through.
local log = buildat.Logger("sandbox_test")
local magic = require("buildat/core/urho3d")
local M = {}

-- One attempt: a name, and a function that returns what it reached.
-- Reaching *anything* is the failure -- a refusal is either an error
-- (caught here) or a false/nil answer from the verb itself.
local function reached(f)
	local ok, v = pcall(f)
	if not ok then
		return nil, tostring(v):match("^[^\n]*")
	end
	-- A verb that answers false and a reason has refused
	if v == false or v == nil then
		return nil, "refused"
	end
	return v
end

local ATTEMPTS = {
	{"io.open", function() return io.open("/etc/passwd", "rb") end},
	{"os.execute", function() return os.execute("true") end},
	{"os.getenv", function() return os.getenv("HOME") end},
	{"loadstring", function() return loadstring("return 1") end},
	{"dofile", function() return dofile("/etc/passwd") end},
	{"require a standard library", function() return require("os") end},
	{"require _G", function() return require("_G") end},
	{"package", function() return package.loaded end},
	{"debug", function() return debug.getinfo(1) end},
	{"getfenv(0)", function() return getfenv(0) end},
	-- The trusted half of the client's own API
	{"buildat.get_env", function() return buildat.get_env("HOME") end},
	-- A launcher verb since games are apps; a path for a name is what it
	-- must refuse
	{"buildat.start_local_server a path",
		function() return buildat.start_local_server("../apps/vanilla") end},
	{"__buildat_run_code_in_sandbox",
		function() return __buildat_run_code_in_sandbox("return 1") end},
	{"the client's Lua state", function() return __buildat_app end},
	-- The verbs themselves, asked for more than they give
	{"storage_write out of its directory",
		function() return buildat.storage_write("../../evil", "x") end},
	{"storage_read out of its directory",
		function() return buildat.storage_read("../../../etc/passwd") end},
	{"run_extension_file out of its extension",
		function() return buildat.run_extension_file("../launch_world/world.lua") end},
	{"run_extension_file a path",
		function() return buildat.run_extension_file("/etc/passwd") end},
	{"set_preference outside the key set",
		function() return buildat.set_preference("log_level", 6) end},
	{"set_preference a path as the launch UI",
		function() return buildat.set_preference("launch_ui", "../evil") end},
	{"launch something not on the grid",
		function() return buildat.launch("extension/nothing/0") end},
	{"set_launch_ui to something that is not one",
		function() return buildat.set_launch_ui("nosuchthing") end},
	-- The resource cache resolves an absolute or parent-traversal path
	-- outside its dirs, so these would read or probe any file on the
	-- machine; the wrapper refuses a name that is not plainly relative.
	{"cache:Exists an absolute path", function()
		return require("buildat/core/urho3d").cache:Exists("/etc/hostname")
	end},
	{"cache:GetResource an absolute path", function()
		return require("buildat/core/urho3d").cache
				:GetResource("Image", "/etc/hostname")
	end},
	{"cache:Exists a parent-traversal path", function()
		return require("buildat/core/urho3d").cache
				:Exists("....//....//....//....//etc/hostname")
	end},
	-- [SAFE_TABLE_PATCH]: the tables trusted code calls through. The
	-- network permission dialog is drawn by ui_utils.vertical_menu on
	-- uistack.main; a write that lands is a game drawing that dialog.
	{"rewrite ui_utils.vertical_menu", function()
		local u = require("buildat/extension/ui_utils")
		u.vertical_menu = function() end
		return true
	end},
	{"rewrite uistack.main:push", function()
		local s = require("buildat/core/uistack")
		s.main.push = function() end
		return true
	end},
	{"rewrite urho3d's cache", function()
		require("buildat/core/urho3d").cache = {}
		return true
	end},
	{"rewrite buildat.launch", function()
		buildat.launch = function() end
		return true
	end},
	-- [SECURITY_RUN_7]: the UI's scale outlived the connection, and two
	-- members no game used were off the whitelist with it
	{"set the UI's scale", function()
		magic.ui.scale = 0.25
		return true
	end},
	{"Image:FlipHorizontal", function()
		return magic.Image:new().FlipHorizontal
	end},
	{"set the renderer's numViewports", function()
		magic.renderer.numViewports = 100000
		return true
	end},
	-- [KIT_PLAY_PICTURE_UI] the UI over a picture: the server's camera's
	-- alone (it lays the screen out anew and draws the UI where a script
	-- reads it back)
	{"picture_ui outside the server's camera", function()
		local tex = magic.Texture2D:new()
		tex:SetSize(64, 64, magic.Graphics.GetRGBAFormat(),
				magic.TEXTURE_RENDERTARGET)
		return magic.picture_ui(tex)
	end},
	{"rewrite string.format", function()
		string.format = function() end
		return true
	end},
	-- [SAFE_CALLER_FRAME]: a verb that read its caller's frame read the
	-- client's own through a pcall
	{"eval through a pcall", function()
		local _, ok, v = pcall(buildat.eval, "return io")
		return ok and v
	end},
	{"subscribe a client global by name through a pcall", function()
		local ok, name = pcall(magic.SubscribeToEvent, "Update", "tostring")
		return ok and name
	end},
}

function M.run()
	local got_through = {}
	for _, a in ipairs(ATTEMPTS) do
		local v, why = reached(a[2])
		if v ~= nil then
			got_through[#got_through + 1] = a[1]
			log:warning("launch sandbox: " .. a[1] .. " GOT THROUGH")
		else
			log:verbose("launch sandbox: " .. a[1] .. ": " .. tostring(why))
		end
	end
	-- **Polling the keys** ([SANDBOX_API_AUDIT]): every letter's
	-- GetKeyPress each frame, logged as it is seen. The check presses one
	-- here (it must be seen: the poll works) and one into the Starport ID
	-- dialog's field (it must not: a secret field's keys are nobody
	-- else's, polled or not)
	-- **Writing the secret field** ([SECURITY_RUN_7]): once the Starport
	-- ID dialog is up, its password field walked to and written three
	-- ways; a write that lands could swap what the user typed for a
	-- password the script knows. Each must be refused.
	local wrote = false
	-- [EXT_CALLER_FRAME] Another extension's tail calls write "peer_mark"
	-- each frame (sandbox_test_peer); none may land in this launch UI's
	-- storage or cache. Cleared first: the checks' user dir is kept.
	buildat.storage_write("peer_mark", "")
	buildat.cache_write("peer_mark", "")
	local peer = require("buildat/extension/sandbox_test_peer")
	local ran, text = peer.hook()
	log:info("launch sandbox: another extension's eval through a function " ..
			"of its own: " .. ((ran and type(text) == "string") and
				"RAN AS THE LAUNCH UI" or "refused"))
	-- [SAFE_UNSUB_PEER] And none of its global handlers is the other
	-- extension's to unsubscribe, by name or by the function; the
	-- handler still runs after, and its own unsubscribe still drops it
	local held_runs = 0
	local function held_fn() held_runs = held_runs + 1 end
	local held = magic.SubscribeToEvent("Update", held_fn)
	local peer_removed, peer_own = peer.unsubscribe({{"Update", held},
		{"Update", held_fn}})
	local frames = 0
	-- [KIT_PLAY_PICTURE_UI] **The UI read back from a texture of its own**:
	-- a renderui command in a render path of its own, into its render
	-- target, read back by texture_png. The UI holds the client's own (the
	-- trust colour shown on this screen), which no script may read: the
	-- picture is the clear's one colour unless the UI got in.
	local probe
	local function ui_probe()
		if frames == 5 then
			local scene = magic.Scene:new()
			scene:CreateComponent("Octree")
			local cam = scene:CreateChild("cam"):CreateComponent("Camera")
			local tex = magic.Texture2D:new()
			tex:SetSize(320, 180, magic.Graphics.GetRGBAFormat(),
					magic.TEXTURE_RENDERTARGET)
			local vp = magic.Viewport:new(scene, cam)
			local path = vp.renderPath:Clone()
			path:GetCommand(1).type = magic.CMD_RENDERUI
			vp.renderPath = path
			local s = tex:GetRenderSurface()
			s:SetViewport(0, vp)
			s.updateMode = magic.SURFACE_MANUALUPDATE
			s:QueueUpdate()
			probe = {tex = tex, scene = scene, vp = vp, path = path}
		elseif frames == 8 and probe then
			local png = magic.texture_png(probe.tex)
			local img, seen, n = magic.Image:new(), {}, 0
			if png and magic.image_load_data(img, png) then
				for y = 0, img.height - 1, 2 do
					for x = 0, img.width - 1, 2 do
						local c = img:GetPixel(x, y)
						local k = string.format("%.2f %.2f %.2f", c.r, c.g, c.b)
						if not seen[k] then
							seen[k], n = true, n + 1
						end
					end
				end
			end
			log:info("launch sandbox: the UI read back from a texture of its " ..
					"own: " .. (png and n .. " colours" or "no picture"))
			probe = nil
		end
	end
	magic.SubscribeToEvent("Update", function()
		frames = frames + 1
		ui_probe()
		if frames == 3 then
			log:info("launch sandbox: another extension's unsubscribes of " ..
					"its handler: " .. peer_removed .. " removed, its own " ..
					tostring(peer_own) .. "; the handler ran " .. held_runs ..
					" times after; its own unsubscribe: " ..
					magic.UnsubscribeFromEvent("Update", held))
			local s, c = buildat.storage_read("peer_mark"),
					buildat.cache_read("peer_mark")
			log:info("launch sandbox: another extension's writes in the " ..
					"launch UI's storage and cache: " ..
					((s == "" and c == "") and "none" or
						"WRITTEN (" .. tostring(s) .. ", " .. tostring(c) .. ")"))
		end
		for key = 97, 122 do
			if magic.input:GetKeyPress(key) then
				log:info("launch sandbox: polled " .. string.char(key))
			end
		end
		-- GetChild() takes no recursive flag: walked by index
		local function find(el, depth)
			if el:GetName() == "__trusted_secret" then return el end
			if depth > 12 then return nil end
			for i = 0, el:GetNumChildren() - 1 do
				local c = el:GetChild(i)
				local f = c and find(c, depth + 1)
				if f then return f end
			end
		end
		local e = not wrote and find(magic.ui.root, 0)
		if e then
			wrote = true
			local refused = 0
			for name, w in pairs({
				text = function() e.text = "known" end,
				SetText = function() e:SetText("known") end,
				maxLength = function() e.maxLength = 1 end,
			}) do
				if pcall(w) then
					log:warning("launch sandbox: wrote the secret field by " .. name)
				else
					refused = refused + 1
				end
			end
			log:info("launch sandbox: secret field writes refused: " .. refused)
			-- [SAFE_UNSUB_FOREIGN] And its Return: Urho3D keeps one
			-- handler per element and event, so a script's subscription
			-- took the client's login over
			local took = pcall(magic.SubscribeToEvent, e, "TextFinished",
					function() end)
			log:info("launch sandbox: the secret field's TextFinished " ..
					(took and "TAKEN OVER" or "kept"))
		end
	end)
	-- The one line a check reads
	log:info("launch sandbox: " .. #ATTEMPTS .. " reaches tried, " ..
			#got_through .. " got through" ..
			(#got_through > 0 and ": " .. table.concat(got_through, ", ") or ""))
	return #got_through
end

return M
-- vim: set noet ts=4 sw=4:
