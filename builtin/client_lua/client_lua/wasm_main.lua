-- Buildat: client_lua/wasm_main.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- [CLIENT_WASM] The default client_main: a module whose meta.json says
-- "client_main": "wasm" has its client run by this instead of Lua of its
-- own (the loader runs it with the module's name). It loads the module's
-- .wasm, makes a scene for it to draw into and hands it the handles, and
-- forwards the frames, the input and the module's packets to it. The
-- exports and the events' bytes are in interface/wasm_api.h.
-- It also binds the module's calls of interface/buildat_client.h
-- ([CLIENT_WASM_BINDINGS]): each is made here, in this sandbox, by the
-- dispatcher below, as this module's own script would make it.
local magic = require("buildat/extension/urho3d")

-- The mesh nodes a module is handed, each with a CustomGeometry and a
-- texture of its own
local NODES = 8
-- Events kept while the module loads; past these they are dropped
local PENDING_MAX = 256

local EV_START, EV_KEY_DOWN, EV_KEY_UP, EV_MOUSE_DOWN, EV_MOUSE_UP,
		EV_MOUSE_MOVE, EV_WHEEL, EV_PACKET, EV_RESIZE, EV_OBJECT =
		1, 2, 3, 4, 5, 6, 7, 8, 9, 10

-- Little-endian 32-bit words
local function words(t)
	local s = {}
	for i, v in ipairs(t) do
		v = math.floor(v) % 4294967296
		s[i] = string.char(v % 256, math.floor(v / 256) % 256,
				math.floor(v / 65536) % 256, math.floor(v / 16777216))
	end
	return table.concat(s)
end

return function(module)
	local log = buildat.Logger(module)
	local m, why = buildat.wasm_load(module)
	if not m then
		log:error("the default client_main: no wasm: "..tostring(why))
		return
	end

	local scene = magic.Scene()
	scene:CreateComponent("Octree")
	local camera_node = scene:CreateChild("Camera")
	camera_node.position = magic.Vector3(0, 0, -5)
	local camera = camera_node:CreateComponent("Camera")
	magic.set_preferred_viewports({magic.Viewport:new(scene, camera)})
	local light_node = scene:CreateChild("Light")
	light_node.direction = magic.Vector3(0.5, -1, 0.8)
	local light = light_node:CreateComponent("Light")
	light.lightType = magic.LIGHT_DIRECTIONAL
	-- A white texel until the module sets the texture: the vertex colours
	-- show as they are
	local white = magic.Image:new()
	white:SetSize(1, 1, 4)
	white:SetPixelInt(0, 0, 0xffffffff)
	local handed = {}
	for i = 1, NODES do
		local node = scene:CreateChild("Mesh"..i)
		local cg = node:CreateComponent("CustomGeometry")
		local tex = magic.Texture2D:new()
		tex:SetData(white)
		local mat = magic.Material:new()
		mat:SetTechnique(0, magic.cache:GetResource("Technique",
				"Techniques/DiffVCol.xml"))
		mat:SetTexture(magic.TU_DIFFUSE, tex)
		cg:SetMaterial(0, mat)
		handed[i] = {node, tex}
	end

	local state = "loading"
	local pending = {}
	local dropped = false
	local errors = 0
	local function push(bytes)
		if state == "loading" then
			if #pending < PENDING_MAX then
				table.insert(pending, bytes)
			else
				dropped = true
			end
			return
		end
		if state ~= "running" then
			return
		end
		-- Past the queue's cap (the module takes none): dropped
		if not pcall(m.push, m, bytes) then
			dropped = true
		end
	end
	local function stop(why)
		state = "stopped"
		log:error("the default client_main stopped the module: "..why)
	end

	-- [CLIENT_WASM_BINDINGS] The module's calls, as wasm.cpp hands them:
	-- what kind, the class and the member its import names, and the values
	-- (an object as the wrapper its handle holds; a Vector3, Color, ...
	-- made by "value" first). Each is the sandbox's own call, with its
	-- checks; an error is the module's trap. A verb is called from this
	-- frame, not tail-called (pass), so that a gate reading its caller's
	-- frame finds this served file's.
	local function pass(...)
		return ...
	end
	m:bind(function(kind, class, member, ...)
		if kind == "call" then
			local self = ...
			return self[member](...)
		elseif kind == "get" then
			local self = ...
			return self[member]
		elseif kind == "set" then
			local self, v = ...
			self[member] = v
		elseif kind == "static" then
			local c = magic[class]
			return c[member](c, ...)
		elseif kind == "new" or kind == "value" then
			return magic[class](...)
		elseif kind == "global" then
			return magic[member]
		elseif kind == "constant" then
			local v = magic[(...)]
			if type(v) ~= "number" and type(v) ~= "string" then
				error("constant("..tostring((...))..
						"): not a number or a string of the sandbox's")
			end
			return v
		elseif kind == "subscribe" then
			-- Each of the object's events of the name, to the queue with
			-- the handle the module subscribed with
			local object, event, handle = ...
			if type(event) ~= "string" or #event > 64 then
				error("SubscribeToEvent(object, name): a name")
			end
			magic.SubscribeToEvent(object, event, function()
				push(words({EV_OBJECT, handle, #event})..event)
			end)
		elseif kind == "subscribe_global" then
			-- A global event, to the queue with handle 0
			local event = ...
			if type(event) ~= "string" or #event > 64 then
				error("SubscribeToEvent(name): a name")
			end
			local name = magic.SubscribeToEvent(event, function()
				push(words({EV_OBJECT, 0, #event})..event)
			end)
			return name
		elseif kind == "safe" then
			-- This file's buildat: a server's (its served overrides)
			return pass(buildat[member](...))
		elseif kind == "magic" then
			return pass(magic[member](...))
		else
			error("no such call: "..tostring(kind))
		end
	end)

	-- The module's packets, by the names its packets() export lists
	local function subscribe_packets()
		local ok, p = pcall(m.call, m, "packets")
		if not ok or not p or p == 0 then
			return
		end
		local bytes = {}
		for i = 0, 4095 do
			local ok, c = pcall(m.read, m, p + i, 1)
			if not ok or c == "\0" then
				break
			end
			bytes[#bytes + 1] = c
		end
		for name in table.concat(bytes):gmatch("%S+") do
			if name:match("^[%w_]+$") and #name <= 64 then
				buildat.sub_packet(module..":"..name, function(data)
					-- BUILDAT_EVENT_MAX holds the largest
					if #data > 65536 then
						log:warning("the default client_main: a packet "..
								name.." of "..#data.." bytes dropped (65536 at most)")
						return
					end
					push(words({EV_PACKET, #name})..name..data)
				end)
			else
				log:warning("the default client_main: not a packet name: "..
						name:sub(1, 70))
			end
		end
	end

	magic.SubscribeToEvent("Update", function(_, d)
		-- The scene held by this handler: a viewport keeps only a weak
		-- reference, and a scene nothing refers to is collected, its
		-- nodes detached under the module ([HOLD_REF_UAF])
		local _ = scene
		if state == "loading" then
			local status, detail = m:status()
			if status == "loading" then
				return
			end
			if status ~= "ready" then
				return stop(tostring(detail))
			end
			state = "running"
			local start = {EV_START, m:handle(camera_node), m:handle(light_node),
					magic.graphics.width, magic.graphics.height, NODES}
			for _, nt in ipairs(handed) do
				table.insert(start, m:handle(nt[1]))
				table.insert(start, m:handle(nt[2]))
			end
			subscribe_packets()
			push(words(start))
			for _, bytes in ipairs(pending) do
				push(bytes)
			end
			pending = nil
		end
		if state ~= "running" then
			return
		end
		if dropped then
			dropped = false
			log:warning("the default client_main: events dropped (the "..
					"module took none)")
		end
		local ok, err = pcall(m.call, m, "frame", d:GetFloat("TimeStep"))
		if not ok then
			if m:status() == "failed" then
				return stop(select(2, m:status()))
			end
			errors = errors + 1
			if errors <= 3 then
				log:error("frame: "..tostring(err)..
						(errors == 3 and " (no more of these logged)" or ""))
			end
		end
	end)
	magic.SubscribeToEvent("KeyDown", function(_, d)
		push(words({EV_KEY_DOWN, d:GetInt("Key"), d:GetBool("Repeat") and 1 or 0,
				d:GetInt("Qualifiers")}))
	end)
	magic.SubscribeToEvent("KeyUp", function(_, d)
		push(words({EV_KEY_UP, d:GetInt("Key")}))
	end)
	magic.SubscribeToEvent("MouseButtonDown", function(_, d)
		push(words({EV_MOUSE_DOWN, d:GetInt("Button")}))
	end)
	magic.SubscribeToEvent("MouseButtonUp", function(_, d)
		push(words({EV_MOUSE_UP, d:GetInt("Button")}))
	end)
	magic.SubscribeToEvent("MouseMove", function(_, d)
		push(words({EV_MOUSE_MOVE, d:GetInt("X"), d:GetInt("Y"), d:GetInt("DX"),
				d:GetInt("DY")}))
	end)
	magic.SubscribeToEvent("MouseWheel", function(_, d)
		push(words({EV_WHEEL, d:GetInt("Wheel")}))
	end)
	magic.SubscribeToEvent("ScreenMode", function(_, d)
		push(words({EV_RESIZE, d:GetInt("Width"), d:GetInt("Height")}))
	end)
end
