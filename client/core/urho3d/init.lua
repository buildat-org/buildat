-- Buildat: extension/urho3d
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("extension/urho3d")
local dump = buildat.dump
local magic_sandbox = require("buildat/core/magic_sandbox")
local safe_globals = dofile(buildat.extension_path("urho3d").."/safe_globals.lua")
local safe_events = dofile(buildat.extension_path("urho3d").."/safe_events.lua")
-- command_seq:<name> is any name a command sequence's `event` line gives,
-- with the rest of the line as Param ([CMD_EVENT]); the prefix is the
-- whitelist entry
local COMMAND_SEQ_EVENT = {Param = {variant = "String", safe = "string"}}
local function safe_event_def(name)
	if safe_events[name] then
		return safe_events[name]
	end
	if type(name) == "string" and name:sub(1, 12) == "command_seq:" then
		return COMMAND_SEQ_EVENT
	end
	return nil
end
local safe_classes = dofile(buildat.extension_path("urho3d").."/safe_classes.lua")

local Safe = {}
local Unsafe = {}

--
-- Safe interface
--

local function wc(name, def)
	Safe[name] = magic_sandbox.wrap_class(name, def)
end

local function wrap_instance(name, instance)
	if instance == nil then
		return nil
	end
	local class = Safe[name]
	local class_meta = getmetatable(class)
	if not class_meta then error(dump(name).." is not a whitelisted class") end
	return class_meta.wrap(instance)
end

local function type_allows_nil(valid_types)
	if valid_types == '__nil' then
		return true
	end
	if type(valid_types) == 'table' then
		local meta = getmetatable(valid_types)
		if meta and meta.type_name then
			return false
		end
		for _, t in ipairs(valid_types) do
			if t == '__nil' then
				return true
			end
		end
	end
	return false
end

-- One argument checked and made unsafe; `what` names the call in the
-- error
local function checked(what, i, v, t)
	if v == nil and not type_allows_nil(t) then
		error(what.." argument "..i.." is nil")
	end
	return magic_sandbox.safe_to_unsafe(v, t, what.." argument "..i)
end

-- f called with the checked arguments, the trailing nils left off as
-- unpack(t, 1, table.maxn(t)) did: an argument passed as nil is not one
-- absent to tolua, which counts them. Then the returns made safe.
-- **Without a table a call** ([SANDBOX_CALLS]): up to four arguments and
-- two returns, which is nearly all of them; the rest go the long way.
local function call_checked(f, return_types, a1, a2, a3, a4)
	local r1, r2
	if a4 ~= nil then r1, r2 = f(a1, a2, a3, a4)
	elseif a3 ~= nil then r1, r2 = f(a1, a2, a3)
	elseif a2 ~= nil then r1, r2 = f(a1, a2)
	elseif a1 ~= nil then r1, r2 = f(a1)
	else r1, r2 = f() end
	local n = #return_types
	if n == 0 then
		return
	elseif n == 1 then
		return magic_sandbox.unsafe_to_safe(r1, return_types[1])
	end
	return magic_sandbox.unsafe_to_safe(r1, return_types[1]),
			magic_sandbox.unsafe_to_safe(r2, return_types[2])
end

-- f, or with method set, the function self has under the name `what`
local function call_checked_long(what, f, return_types, param_types, ...)
	local arg = {...}
	local checked_arg = {}
	for i = 1, #param_types do
		checked_arg[i] = checked(what, i, arg[i], param_types[i])
	end
	if f == nil then
		f = checked_arg[1][what]
		if type(f) ~= 'function' then
			error(dump(what).." not found in instance")
		end
	end
	local wrapped_ret = {}
	local ret = {f(unpack(checked_arg, 1, table.maxn(checked_arg)))}
	for i = 1, #return_types do
		wrapped_ret[i] = magic_sandbox.unsafe_to_safe(ret[i], return_types[i])
	end
	return unpack(wrapped_ret, 1, #return_types)
end

-- (return_types, param_types, f) or (param_types, f)
local function wrap_function(return_types, param_types, f)
	if type(param_types) == 'function' and f == nil then
		f = param_types
		param_types = return_types
		return_types = {"__safe"}
	end
	local what = "wrapped call"
	local np = #param_types
	if np > 4 or #return_types > 2 then
		return function(...)
			return call_checked_long(what, f, return_types, param_types, ...)
		end
	end
	local p1, p2, p3, p4 = param_types[1], param_types[2], param_types[3],
			param_types[4]
	return function(a1, a2, a3, a4)
		if np >= 1 then a1 = checked(what, 1, a1, p1) else a1 = nil end
		if np >= 2 then a2 = checked(what, 2, a2, p2) else a2 = nil end
		if np >= 3 then a3 = checked(what, 3, a3, p3) else a3 = nil end
		if np >= 4 then a4 = checked(what, 4, a4, p4) else a4 = nil end
		return call_checked(f, return_types, a1, a2, a3, a4)
	end
end

local function self_function(function_name, return_types, param_types)
	local np = #param_types
	local function method(self)
		local f = self[function_name]
		if type(f) ~= 'function' then
			error(dump(function_name).." not found in instance")
		end
		return f
	end
	if np < 1 then
		return function()
			error("At least one argument required (self)")
		end
	end
	if np > 4 or #return_types > 2 then
		return function(...)
			return call_checked_long(function_name, nil, return_types,
					param_types, ...)
		end
	end
	local p1, p2, p3, p4 = param_types[1], param_types[2], param_types[3],
			param_types[4]
	return function(a1, a2, a3, a4)
		a1 = checked(function_name, 1, a1, p1)
		if np >= 2 then a2 = checked(function_name, 2, a2, p2) else a2 = nil end
		if np >= 3 then a3 = checked(function_name, 3, a3, p3) else a3 = nil end
		if np >= 4 then a4 = checked(function_name, 4, a4, p4) else a4 = nil end
		return call_checked(method(a1), return_types, a1, a2, a3, a4)
	end
end

local function simple_property(valid_types)
	return {
		get = function(current_value)
			return magic_sandbox.unsafe_to_safe(current_value, valid_types)
		end,
		set = function(new_value, what)
			return magic_sandbox.safe_to_unsafe(new_value, valid_types, what)
		end,
	}
end

-- A property that can be read and not written: the sandbox's __newindex
-- says so by name. What wants it is a property whose setter has a rule
-- attached -- Input.mouseVisible's, which logs why the cursor changed
-- and stands down in a scripted run.
local function read_only_property(valid_types)
	return {
		get = function(current_value)
			return magic_sandbox.unsafe_to_safe(current_value, valid_types)
		end,
	}
end

for _, name in ipairs(safe_globals) do
	local v = _G[name]
	if v == nil then
		-- Dropped or renamed in later Urho; skip so the sandbox still loads.
		log:info("safe global missing: "..name)
	elseif type(v) ~= 'number' and type(v) ~= 'string' then
		error("Invalid safe global "..dump(name).." type: "..dump(type(v)))
	else
		Safe[name] = v
	end
end

local mouse = { hide_wanted = false, overlay_open = false }

-- What set_preferred_viewports() was last given, unsafe, for
-- renderer:GetViewport(): a preferred viewport drawn at a render scale, or
-- in the scripted client at its logical size ([SEQ_FIXED_SIZE]), goes onto
-- a texture and the renderer holds no viewports at all -- and every
-- reader of GetViewport(0) (voxel_shading's shader parameters, the sky
-- visibility, the parity modes' render path) got nil and gave up in
-- silence: the reference sets since 2026-09-20 had no bounce, ground or
-- lamp term (found on the interior fit). The wrapper answers with the
-- game's own when the renderer has none.
local preferred = {}

safe_classes.define(Safe, {
	wc = wc,
	preferred_viewport = function(index) return preferred[index + 1] end,
	wrap_instance = wrap_instance,
	wrap_function = wrap_function,
	self_function = self_function,
	simple_property = simple_property,
	read_only_property = read_only_property,
	check_safe_resource_name = Unsafe.check_safe_resource_name,
	mouse = mouse,
	--resave_file = Unsafe.resave_file,
})

setmetatable(Safe, {
	__index = function(t, k)
		local v = rawget(t, k)
		if v ~= nil then return v end
		error("extension/urho3d: Class "..dump(k).." is not whitelisted")
	end,
})

-- SubscribeToEvent
--
-- 1.7 LuaScriptEventInvoker stores one handler per event type (last subscribe
-- wins). 2014 kept a vector of functions. Multiplex global events so voxelworld
-- and games can both receive Update.

local urho_SubscribeToEvent = SubscribeToEvent
-- Dropped so Lua cannot replace the mux. Object-specific subs still use
-- urho_SubscribeToEvent (one handler per sender+event, which is correct).
-- UnsubscribeFromEvent("Update") would strip the mux, so drop it too.
SubscribeToEvent = nil
UnsubscribeFromEvent = nil

local sandbox_callback_to_global_function_name = {}
local next_sandbox_global_function_i = 1
local global_event_mux = {} -- event_type -> { {name=, fn=, sandbox=}, ... }
-- Set around add_global_event_handler() by a subscription made from the
-- sandbox; see caller_in_sandbox()
local from_sandbox = false
-- **Which extension subscribed**, taken from its chunk name, so that
-- leaving a game can drop the game's handlers without dropping the
-- launcher's -- which are sandboxed too now ([LAUNCH_SANDBOX]), and
-- were going with them: after a return the room drew and answered
-- nothing (2026-09-23).
local from_sandbox_owner = nil
local function sandbox_owner()
	for level = 2, 6 do
		local info = debug.getinfo(level, "S")
		if not info then break end
		local name = (info.source or ""):match("^@?([%w_]+)/[%w_%-%.]+$")
		if name then return name end
	end
	return nil
end
local global_event_mux_installed = {}

local function add_global_event_handler(event_type, cb_name, fn)
	if not global_event_mux_installed[event_type] then
		global_event_mux[event_type] = {}
		-- A global's name, so only letters and digits: an event named
		-- with a colon (command_seq:scan, [CMD_EVENT]) is a function
		-- Urho3D cannot look up otherwise
		local mux_name = "__buildat_mux_"..event_type:gsub("[^%w_]", "_")
		_G[mux_name] = function(event_type_thing, unsafe_event_data)
			-- A handler is allowed to unsubscribe from inside the event --
			-- leaving a session on Escape does -- so a removal makes a new
			-- list (drop_entries) and leaves this one as it was, its entry
			-- marked: one unsubscribed by an earlier handler is not called,
			-- as it may have been holding what it was about to touch. One
			-- subscribed meanwhile waits for the next event.
			local list = global_event_mux[event_type]
			for i = 1, #list do
				local entry = list[i]
				if not entry.removed then
					entry.fn(event_type_thing, unsafe_event_data)
				end
			end
		end
		urho_SubscribeToEvent(event_type, mux_name)
		global_event_mux_installed[event_type] = true
	end
	table.insert(global_event_mux[event_type], {name = cb_name, fn = fn,
			sandbox = from_sandbox, owner = from_sandbox_owner})
end

-- The handlers of an event that `drop` picks, out: a new list, so that
-- a mux walking the old one is not shifted under, and each one marked
-- for that mux to skip. Returns how many.
local function drop_entries(event_type, drop)
	local list, kept, n = global_event_mux[event_type], {}, 0
	for _, entry in ipairs(list) do
		if drop(entry) then
			entry.removed = true
			n = n + 1
		else
			kept[#kept + 1] = entry
		end
	end
	if n > 0 then
		global_event_mux[event_type] = kept
	end
	return n
end

-- Every global handler a sandboxed script subscribed, dropped; the
-- object-specific ones go with their objects
-- `keep` is an extension whose handlers are not a game's -- the launch
-- UI's, which has to still be there when the game is gone
local function drop_sandbox_handlers(keep)
	local n = 0
	for event_type in pairs(global_event_mux) do
		n = n + drop_entries(event_type, function(e)
			return e.sandbox and not (keep and e.owner == keep)
		end)
	end
	log:info("drop_sandbox_handlers(): "..n.." handlers dropped")
	return n
end

-- Every global handler one sandboxed extension subscribed, dropped: a
-- launch UI closed rather than left running under the next one
-- (set_launch_ui's close)
local function drop_handlers_of(owner)
	local n = 0
	for event_type in pairs(global_event_mux) do
		n = n + drop_entries(event_type, function(e)
			return e.sandbox and e.owner == owner
		end)
	end
	log:info("drop_handlers_of(" .. owner .. "): " .. n .. " handlers dropped")
	return n
end

local function remove_global_event_handler(event_type, cb_name)
	if not global_event_mux[event_type] then
		return
	end
	drop_entries(event_type, function(e) return e.name == cb_name end)
end

-- The keys the client keeps ([CLIENT_KEYS]); safe_classes' Input reads
-- them as up
__buildat_client_keys = {[KEY_F9] = true, [KEY_F10] = true, [KEY_F11] = true,
		[KEY_F12] = true}
local overlay_key = KEY_F9
-- **A key taken for the rest of its frame** ([UI_DROPDOWN]): the Escape
-- that closed a dropdown's popup, which no KeyDown handler hears, an
-- app's own included; uistack sets it and clears it each Update
local key_taken = nil
function __buildat_take_key(key)
	key_taken = key
end
-- **Rebound in the key store** ([LAUNCH_MENU_V2] step 3, api.lua's
-- set_client_key): the set changes in place, as safe_classes reads it, and
-- the engine's own three are told (app.cpp's on_keydown). A key unbound
-- is 0 and goes back to the apps.
function __buildat_apply_client_keys(names)
	local function code(name)
		return name and name ~= "" and input:GetKeyFromName(name) or 0
	end
	for k in pairs(__buildat_client_keys) do __buildat_client_keys[k] = nil end
	local codes = {}
	for _, which in ipairs({"overlay", "profiler", "fullscreen", "screenshot"}) do
		codes[which] = code(names[which])
		if codes[which] ~= 0 then __buildat_client_keys[codes[which]] = true end
	end
	overlay_key = codes.overlay ~= 0 and codes.overlay or KEY_F9
	__buildat_set_client_keys(codes.profiler, codes.fullscreen, codes.screenshot)
end
__buildat_apply_client_keys(__buildat_client_key_names())

function Safe.SubscribeToEvent(x, y, z)
	log:debug("Safe.SubscribeToEvent("..dump(x)..", "..dump(y)..", "..dump(z)..")")
	-- Whether the subscriber is sandboxed game code: its environment's
	-- buildat says so ([MENU_CONTEXT] drops those handlers on leaving)
	local caller_env = getfenv(2)
	local subscriber_in_sandbox = type(caller_env) == "table" and
			type(caller_env.buildat) == "table" and
			caller_env.buildat.is_in_sandbox == true
	local object = x
	local sub_event_type = y
	local callback = z
	if z == nil then
		object = nil
		sub_event_type = x
		callback = y
	end
	if object then
		if not getmetatable(object) or not getmetatable(object).unsafe then
			error("SubscribeToEvent(): Object must be sandboxed")
		end
	end
	if not safe_event_def(sub_event_type) then
		error("Event type is not whitelisted: "..dump(sub_event_type))
	end
	if type(callback) == 'string' then
		-- Allow supplying callback function name like Urho3D does by default
		local caller_environment = getfenv(2)
		callback = caller_environment[callback]
		if type(callback) ~= 'function' then
			error("SubscribeToEvent(): '"..callback..
					"' is not a global function in current sandbox environment")
		end
	else
		-- Allow directly supplying callback function
	end
	local global_function_i = next_sandbox_global_function_i
	next_sandbox_global_function_i = next_sandbox_global_function_i + 1
	local global_callback_name = "__buildat_sandbox_callback_"..global_function_i
	sandbox_callback_to_global_function_name[callback] = global_callback_name
	-- A script's own function, as against the client's: what a sandbox
	-- makes runs in a sandbox environment, never in this one
	local callback_is_sandboxed = getfenv(callback) ~= _G
	-- The delivery is made once and run per event ([SANDBOX_CALLS]); the
	-- event reaches it through these two, which it reads before it calls
	-- the callback, so an event the callback causes cannot change them
	-- under it
	local current_thing, current_data
	local error = error
	local run = __buildat_sandboxed_runner(function()
		local event_type_thing, unsafe_event_data = current_thing, current_data
		current_thing, current_data = nil, nil
		-- How the hell does one get a string out of event_type_thing?
		-- It is not a Variant, and none of the Lua examples try to do anything
		-- with it.
		-- Let's just assume it's the correct one...
		local got_event_type = sub_event_type
		-- Filter event_data (Urho3D::VariantMap)
		local safe_fields = safe_event_def(got_event_type)
		if not safe_fields then
			log:warning("Received unsafe event: "..dump(got_event_type))
			return
		end
		-- 1.7 VariantMap is indexed: eventData["Key"] returns a Variant.
		local safe_event_data = Safe.VariantMap()
		for field_name, field_def in pairs(safe_fields) do
			local variant_type = field_def.variant
			local safe_type = field_def.safe
			local variant = unsafe_event_data[field_name]
			if variant == nil then
				error("Value for field "..dump(field_name).." in "..
						dump(got_event_type).." is nil")
			end
			-- 1.7 VariantMap __index returns an empty Variant for missing
			-- keys, not nil. Treat empty as missing.
			if variant.IsEmpty and variant:IsEmpty() then
				error("Value for field "..dump(field_name).." in "..
						dump(got_event_type).." is empty")
			end
			local safe_value = nil
			if variant_type == "Ptr" then
				local get_type = field_def.get_type or safe_type
				local unsafe_value = variant:GetPtr(get_type)
				if unsafe_value == nil then
					error("Value for field "..dump(field_name).." as "..
							dump(safe_type).." in "..dump(got_event_type)..
							" gotten as "..dump(get_type).." is nil")
				end
				safe_value = wrap_instance(safe_type, unsafe_value)
				safe_event_data:SetPtr(field_name, safe_value)
			else
				local get_type = field_def.get_type or variant_type
				local getter = variant["Get"..get_type]
				if type(getter) ~= "function" then
					error("Variant has no Get"..get_type.." for field "..
							dump(field_name).." in "..dump(got_event_type))
				end
				local unsafe_value = getter(variant)
				if safe_type == 'number' or safe_type == 'string' or
						safe_type == 'boolean' then
					safe_value = magic_sandbox.unsafe_to_safe(unsafe_value, safe_type)
				else
					safe_value = wrap_instance(safe_type, unsafe_value)
				end
				local setter = safe_event_data["Set"..get_type]
				if type(setter) ~= "function" then
					error("Safe.VariantMap has no Set"..get_type)
				end
				setter(safe_event_data, field_name, safe_value)
			end
		end
		-- Call callback
		if object then
			callback(object, got_event_type, safe_event_data)
		else
			callback(got_event_type, safe_event_data)
		end
	end)
	_G[global_callback_name] = function(event_type_thing, unsafe_event_data)
		-- **Keys typed into a secret field are nobody else's**
		-- ([SECURITY_RUN_1]): a script's KeyDown is every key pressed,
		-- with its shift, so it read a Starport password as it was typed
		-- into the client's own login dialog
		if callback_is_sandboxed and (sub_event_type == "KeyDown" or
				sub_event_type == "KeyUp" or
				sub_event_type == "TextInput") and
				magic_sandbox.keys_withheld() then
			return
		end
		-- **F9 to F12 are the client's alone** ([TRUST_CODE],
		-- [CLIENT_KEYS]): nobody here hears them, the client's own
		-- extensions included, as a script's callback can be called
		-- through one of theirs (uistack's SubscribeToStackEvent); so an
		-- app cannot bind one and have it do two things. The overlay's
		-- own handler is subscribed on the mux directly.
		if (sub_event_type == "KeyDown" or sub_event_type == "KeyUp") and
				__buildat_client_keys[unsafe_event_data["Key"]:GetInt()] then
			return
		end
		-- A key taken for the rest of its frame (uistack.take_key)
		if sub_event_type == "KeyDown" and key_taken ==
				unsafe_event_data["Key"]:GetInt() then
			return
		end
		current_thing, current_data = event_type_thing, unsafe_event_data
		run()
	end
	if object then
		local unsafe_object = getmetatable(object).unsafe
		urho_SubscribeToEvent(unsafe_object, sub_event_type, global_callback_name)
	else
		from_sandbox = subscriber_in_sandbox
		from_sandbox_owner = subscriber_in_sandbox and sandbox_owner() or nil
		add_global_event_handler(sub_event_type, global_callback_name,
				_G[global_callback_name])
		from_sandbox, from_sandbox_owner = false, nil
	end
	log:debug("-> global_callback_name="..dump(global_callback_name))
	return global_callback_name
end

-- **What is subscribed by name unsubscribes by the same name.**
-- SubscribeToEvent stores the handler under a generated global name and
-- hands that name back, so an unsubscribe given what Urho3D's own API
-- takes -- a function, or the name of one in the caller's environment --
-- matched nothing and the handler went on firing over a screen it had
-- already removed (2026-09-24: the console's Escape handler, after the
-- console was closed).
function Safe.UnsubscribeFromEvent(sub_event_type, cb_name)
	log:debug("Safe.UnsubscribeFromEvent("..dump(sub_event_type)..", "..dump(cb_name)..")")
	local cb = cb_name
	if type(cb) == "string" then
		local caller_environment = getfenv(2)
		cb = type(caller_environment) == "table" and
				caller_environment[cb_name] or nil
	end
	if type(cb) == "function" then
		cb_name = sandbox_callback_to_global_function_name[cb] or cb_name
	end
	remove_global_event_handler(sub_event_type, cb_name)
end

-- A scene drawn into a texture instead of into the window, for a thumbnail:
-- see l_render_scene_to_texture() in src/lua_bindings/misc_urho3d.cpp for what
-- the texture does and does not do.
Safe.render_scene_to_texture = wrap_function({"Scene", "Node", "number",
		"number"}, function(scene, camera_node, w, h)
	return wrap_instance("Texture2D", __buildat_render_scene_to_texture(
			scene, camera_node, w, h))
end)

-- **A whole image in one call** ([ROOM_BOOT]): the bytes are w * h *
-- components of them, row by row from the top left, and for four
-- components that is R, G, B, A. A generated tile written a pixel at a
-- time is four thousand crossings of the sandbox; this is one.
Safe.image_set_data = wrap_function({"Image", "number", "number", "number",
		"string"}, function(image, w, h, components, data)
	-- wrap_function has already unwrapped the Image
	__buildat_image_set_data(image, w, h, components, data)
end)

-- **A PNG or JPEG from its bytes** ([HEARTH_ATTACHMENTS]), as a server
-- sends a picture at run time: false for anything else, over max_side
-- pixels a side (1024 unless said, 4096 at most) or over max_side squared
-- bytes
Safe.image_load_data = wrap_function({"Image", "string", {"number", "__nil"}},
		function(image, data, max_side)
	return __buildat_image_load_data(image, data, max_side)
end)

-- The viewports the user's graphics preferences are applied to, as against
-- the raw renderer:SetViewport() ones which are drawn the way the game says
-- and nothing else. Use this instead of renderer:SetViewport(): the engine
-- draws the scene at the render_scale the user asked for, under a UI that
-- stays at native resolution, and the viewport stays the game's own -- what
-- it does to renderPath afterwards still works.
--
--     magic.set_preferred_viewports({viewport})            -- one view
--     magic.set_preferred_viewports({vp_top, vp_bottom})   -- two
--     magic.set_preferred_viewports({})                    -- teardown
--
-- A game that does not call this is drawn at native resolution and keeps
-- working; the preference is a preference.
function Safe.set_preferred_viewports(viewports)
	if type(viewports) ~= 'table' then
		error("set_preferred_viewports(): expected a table of Viewports")
	end
	local unsafe = {}
	for i = 1, #viewports do
		unsafe[i] = magic_sandbox.safe_to_unsafe(viewports[i], "Viewport")
	end
	preferred = unsafe
	__buildat_set_preferred_viewports(unsafe)
end

-- **Who has the screen** ([LAUNCH_WORLD], 2026-09-24: the room stands
-- down too early). A launcher that keeps drawing while a game loads has
-- to know when the game actually takes the view, and taking the view is
-- set_preferred_viewports. **The count is the client's**, not this
-- file's: each sandbox gets its own copy of this extension, so a game
-- bumping a count here is not something the launcher's copy can see.
function Safe.viewport_generation()
	return __buildat_viewport_generation()
end

-- **A field of view of the screen's short side** (user, 2026-09-30): a
-- camera's fov is vertical, which on a portrait screen is a slot. deg is
-- then the narrower of the width and the height, and what comes back is the
-- vertical fov that gives it.
function Safe.fov_for(deg)
	local w, h = Safe.graphics.width, Safe.graphics.height
	if h <= w or w <= 0 then
		return deg
	end
	return math.deg(2 * math.atan(math.tan(math.rad(deg) / 2) * h / w))
end

-- The camera kept at fov_for(deg), a turned phone and a resized window
-- included; for a game whose fov does not change otherwise
function Safe.keep_fov(camera, deg)
	camera.fov = Safe.fov_for(deg)
	local w, h = Safe.graphics.width, Safe.graphics.height
	Safe.SubscribeToEvent("Update", function()
		local g = Safe.graphics
		if g.width ~= w or g.height ~= h then
			w, h = g.width, g.height
			-- A camera the game has removed since is left alone
			pcall(function() camera.fov = Safe.fov_for(deg) end)
		end
	end)
end

--
-- Unsafe interface
--

-- Just wrap everything to the global environment as we don't have a full list
-- of Urho3D's API available.

setmetatable(Unsafe, {
	__index = function(t, k)
		local v = rawget(t, k)
		if v ~= nil then return v end
		return _G[k]
	end,
})

-- Unsafe SubscribeToEvent with function support

local unsafe_callback_to_global_function_name = {}
local next_unsafe_global_function_i = 1

function Unsafe.SubscribeToEvent(x, y, z)
	local object = x
	local event_name = y
	local callback = z
	if callback == nil then
		object = nil
		event_name = x
		callback = y
	end
	if type(callback) == 'string' then
		-- Allow supplying callback function name like Urho3D does by default
		local caller_environment = getfenv(2)
		callback = caller_environment[callback]
		if type(callback) ~= 'function' then
			error("SubscribeToEvent(): '"..callback..
					"' is not a global function in current unsafe environment")
		end
	else
		-- Allow directly supplying callback function
	end
	local global_function_i = next_unsafe_global_function_i
	next_unsafe_global_function_i = next_unsafe_global_function_i + 1
	local global_callback_name = "__buildat_unsafe_callback_"..global_function_i
	unsafe_callback_to_global_function_name[callback] = global_callback_name
	_G[global_callback_name] = function(event_type, event_data)
		local f = function()
			if object then
				callback(object, event_type, event_data)
			else
				callback(event_type, event_data)
			end
		end
		local ok, err = __buildat_pcall(f)
		if not ok then
			__buildat_fatal_error("Error calling callback: "..err)
		end
	end
	if object then
		urho_SubscribeToEvent(object, event_name, global_callback_name)
	else
		add_global_event_handler(event_name, global_callback_name,
				_G[global_callback_name])
	end
	return global_callback_name
end

-- The mouse's capture, three ways ([FOCUS_LOG] 4). The game says what it
-- wants through SetMouseVisible (hide_wanted); these keep it so across
-- the window manager:
-- * Alt down frees the cursor (ungrab, visible) so alt+tab reaches the
--   WM -- a captured window has the keyboard grabbed too, and without
--   this alt+tab never leaves the game (the playtest of 19:40);
-- * focus lost frees it, focus regained hides and captures it again;
-- * a click while it is free -- a stray Alt, no switch -- captures it.
-- What made the mouse stay free for good was none of these: the game's
-- own mouse key is Tab, and alt+tab handed the Tab to the client first.
Safe.SubscribeToEvent("KeyDown", function(_, event_data)
	if not mouse.hide_wanted then
		return
	end
	local key = event_data:GetInt("Key")
	if key == KEY_ALT or key == KEY_LALT or key == KEY_RALT then
		input:SetMouseChangeReason("alt down")
		input:SetMouseMode(MM_FREE)
		input:SetMouseVisible(true)
	end
end)
Safe.SubscribeToEvent("MouseButtonDown", function()
	if not mouse.hide_wanted or mouse.overlay_open then
		return
	end
	if input:GetMouseMode() == MM_FREE then
		input:SetMouseChangeReason("a click while free")
		input:SetMouseMode(MM_ABSOLUTE)
		input:SetMouseVisible(false)
	end
end)
Safe.SubscribeToEvent("InputFocus", function(_, event_data)
	if not mouse.hide_wanted then
		return
	end
	local focus = event_data:GetBool("Focus")
	input:SetMouseChangeReason(focus and "focus regained" or "focus lost")
	if focus and mouse.overlay_open then
		return
	elseif focus then
		input:SetMouseMode(MM_ABSOLUTE)
		input:SetMouseVisible(false)
	else
		input:SetMouseMode(MM_FREE)
		input:SetMouseVisible(true)
	end
end)

--
-- A removed UI element is dead to the sandbox ([UI_UAF])
--
-- tolua's userdata outlives the element it points at, so a wrapper held
-- past the element's removal -- a closed form's button -- reads freed
-- memory on its next property. The tree sends ElementRemoved for the
-- element before it detaches, while it and its children are whole, so
-- every wrapper of it or of anything under it is marked dead here and
-- errors from then on. A re-parent is a removal followed by an add in
-- the same C++ call (UIElement::InsertChild) with no Lua between: the
-- add un-marks what the removal marked, and only that.
--
-- simplified: a wrapper's dead-ness is by pointer, and a freed element's
-- address can be reused; the add's un-mark then reaches wrappers of an
-- old element that a new one happens to sit on. No crash from it -- the
-- wrapper then reads the new element -- and the fix is a generation
-- counter on the C++ side.

local removed_wrappers = setmetatable({}, {__mode = "k"})

-- The removed subtree, walked while it is whole; the wrappers are then
-- found by lookup and nothing of theirs is called -- a wrapper
-- whose element went without an event (the tree torn down from C++) is
-- exactly the dangling pointer this is here for, and GetParent() on it
-- was the walk's own use-after-free (a driven run, 2026-09-20 16:08)
local function subtree(element, set)
	set[element] = true
	for i = 0, element:GetNumChildren() - 1 do
		subtree(element:GetChild(i), set)
	end
	return set
end

add_global_event_handler("ElementRemoved", "__buildat_ui_dead",
	function(_, data)
		local removed = data["Element"]:GetPtr("UIElement")
		-- Weak too, and `true` for the same reason as magic_sandbox.live
		local set = setmetatable({}, {__mode = "k"})
		local gone = subtree(removed, {})
		-- A removed field kept alive by a wrapper kept the focus, and a
		-- Return long after its dialog closed ran its TextFinished again
		-- (aitta_publish_check, 2026-10-08)
		local focus = ui:GetFocusElement()
		if focus and gone[focus] then
			ui:SetFocusElement(nil)
		end
		for element in pairs(gone) do
			local wrappers = magic_sandbox.live[element]
			if wrappers then
				local why = "UIElement " .. dump(element:GetName()) ..
						" was removed"
				for safe in pairs(wrappers) do
					local meta = getmetatable(safe)
					if not meta.dead then
						meta.dead = why
						set[safe] = true
					end
				end
			end
		end
		removed_wrappers[removed] = set
	end)

add_global_event_handler("ElementAdded", "__buildat_ui_dead",
	function(_, data)
		local added = data["Element"]:GetPtr("UIElement")
		local set = removed_wrappers[added]
		if not set then return end
		removed_wrappers[added] = nil
		for safe in pairs(set) do
			getmetatable(safe).dead = nil
		end
	end)

do
	local holder = Safe.ui.root:CreateChild("UIElement")
	local child = holder:CreateChild("UIElement", "uaf_child")
	local moved = holder:CreateChild("UIElement", "uaf_moved")
	-- The re-parent on the unsafe side: AddChild is not whitelisted
	ui.root:AddChild(getmetatable(moved).unsafe)
	assert(moved:GetName() == "uaf_moved", "a re-parented element read as dead")
	holder:Remove()
	local ok, err = pcall(function() return child:GetName() end)
	assert(not ok and tostring(err):find("uaf_child"),
			"a removed element's child did not error: " .. tostring(err))
	moved:Remove()
	assert(not pcall(function() return moved:GetName() end),
			"a removed element did not error")
end

--
-- What the whitelist actually lets through
--
-- A property missing from safe_classes.lua makes a feature **silently do
-- nothing** -- no error, no warning -- which is the whole cost of a
-- whitelist sweep and the reason one is done in batches. So the classes a
-- sweep adds get a round trip here, once, at load: made through
-- CreateChild the way a game makes them, written to and read back. An
-- element that never arrived in the whitelist errors on CreateChild, and a
-- property that did not arrive comes back wrong.
--
-- util/whitelist_sweep.py is the other half: it says which of Urho3D's
-- classes are still neither wrapped nor refused.

do
	local holder = Safe.ui.root:CreateChild("UIElement")

	local view = holder:CreateChild("ScrollView")
	view.scrollStep = 0.25
	assert(math.abs(view.scrollStep - 0.25) < 1e-6,
			"whitelist: ScrollView.scrollStep did not stick")
	local content = holder:CreateChild("UIElement")
	view.contentElement = content
	assert(view.contentElement ~= nil,
			"whitelist: ScrollView.contentElement did not stick")

	local bar = holder:CreateChild("ScrollBar")
	bar.orientation = O_VERTICAL
	bar.range = 10
	bar.value = 4
	assert(bar.orientation == O_VERTICAL and math.abs(bar.value - 4) < 1e-6,
			"whitelist: ScrollBar did not take its orientation and value")
	bar:ChangeValue(1)
	assert(math.abs(bar.value - 5) < 1e-6,
			"whitelist: ScrollBar:ChangeValue() did nothing")

	local slider = holder:CreateChild("Slider")
	slider.range = 100
	slider.value = 20
	assert(math.abs(slider.value - 20) < 1e-6,
			"whitelist: Slider.value did not stick")

	local progress = holder:CreateChild("ProgressBar")
	progress.range = 1
	progress.value = 0.5
	progress.showPercentText = false
	assert(math.abs(progress.value - 0.5) < 1e-6 and
			progress.showPercentText == false,
			"whitelist: ProgressBar did not take its value")

	local list = holder:CreateChild("ListView")
	assert(list.numItems == 0, "whitelist: a new ListView is not empty")
	list:AddItem(holder:CreateChild("Text"))
	list:AddItem(holder:CreateChild("Text"))
	assert(list.numItems == 2,
			"whitelist: ListView:AddItem() did not add")
	list.selection = 1
	assert(list.selection == 1 and list:IsSelected(1),
			"whitelist: ListView.selection did not stick")
	assert(list:GetItem(0) ~= nil,
			"whitelist: ListView:GetItem() answered nothing")
	list:RemoveItem(0)
	assert(list.numItems == 1,
			"whitelist: ListView:RemoveItem() did not remove")

	local menu = holder:CreateChild("Menu")
	local popup = holder:CreateChild("Window")
	menu.popup = popup
	menu.popupOffset = Safe.IntVector2(0, 20)
	assert(menu.popup ~= nil and menu.popupOffset.y == 20,
			"whitelist: Menu did not take its popup and offset")

	local drop = holder:CreateChild("DropDownList")
	drop.placeholderText = "pick one"
	drop:AddItem(holder:CreateChild("Text"))
	drop:AddItem(holder:CreateChild("Text"))
	assert(drop.numItems == 2 and drop.placeholderText == "pick one",
			"whitelist: DropDownList did not take its items")
	assert(drop.listView ~= nil,
			"whitelist: DropDownList has no list view of its own")

	local tip = holder:CreateChild("ToolTip")
	tip.delay = 0.5
	assert(math.abs(tip.delay - 0.5) < 1e-6,
			"whitelist: ToolTip.delay did not stick")

	local cursor = holder:CreateChild("Cursor")
	cursor.useSystemShapes = false
	assert(cursor.useSystemShapes == false,
			"whitelist: Cursor.useSystemShapes did not stick")

	-- Text3D is a Drawable rather than a UI element, so it wants a node of
	-- its own; the scene is thrown away with it
	local scene = Safe.Scene:new()
	-- With no Octree a drawable says so, once per frame, into everybody
	-- else's log: this scene exists for two property writes and is thrown
	-- away, but it is still a scene
	scene:CreateComponent("Octree")
	local node = scene:CreateChild("whitelist_check")
	local label = node:CreateComponent("Text3D")
	-- **The font first.** Text::SetFontSize() begins "Initial font must be
	-- set" and returns false without one, so a size set before a font is
	-- silently the default -- which is the exact shape of failure this whole
	-- sweep exists to catch, and it was caught here.
	label:SetFont(Safe.cache:GetResource("Font",
			"Fonts/OverpassMono-Regular.ttf"), 24)
	label.text = "over there"
	label.wordwrap = false
	label.fixedScreenSize = true
	assert(label.text == "over there" and label.fontSize == 24 and
			label.fixedScreenSize == true,
			"whitelist: Text3D did not take its font, text and size")
	node:Remove()

	-- Pixels, and the six faces a sky is drawn on. An image made here rather
	-- than read from anywhere: what the cache hands over is the same class.
	local img = Safe.Image:new()
	assert(img:SetSize(4, 4, 4), "whitelist: Image:SetSize() refused")
	assert(img.width == 4 and img.components == 4,
			"whitelist: Image did not take its size")
	img:SetPixel(1, 1, Safe.Color(1, 0, 0, 1))
	local px = img:GetPixel(1, 1)
	assert(px.r > 0.99 and px.g < 0.01,
			"whitelist: a pixel written is not the pixel read")
	assert(img:Resize(2, 2) and img.width == 2,
			"whitelist: Image:Resize() did nothing")

	-- SetData sizes the cube from face 0, so this is the whole of it: one
	-- square image on every face
	local cube = Safe.TextureCube:new()
	local face = Safe.Image:new()
	face:SetSize(4, 4, 4)
	face:Clear(Safe.Color(0, 0, 1, 1))
	for i = 0, 5 do
		assert(cube:SetData(i, face),
				"whitelist: TextureCube:SetData() refused face " .. i)
	end

	-- Arithmetic, which is the whole of the Math batch, so it is checked by
	-- doing some rather than by writing a number and reading it back.
	local iv = Safe.IntVector3(1, 2, 3) + Safe.IntVector3(4, 5, 6)
	assert(iv.x == 5 and iv.y == 7 and iv.z == 9,
			"whitelist: IntVector3 does not add")
	assert(math.abs(Safe.Vector4(1, 2, 3, 4):DotProduct(
			Safe.Vector4(1, 0, 0, 0)) - 1) < 1e-6,
			"whitelist: Vector4 does not dot")
	-- Five out along -Z, pointing back at a box two across around the
	-- origin: the near face is four away
	local ray = Safe.Ray(Safe.Vector3(0, 0, -5), Safe.Vector3(0, 0, 1))
	assert(math.abs(ray:HitDistanceBox(Safe.BoundingBox(-1, 1)) - 4) < 1e-3,
			"whitelist: a ray does not hit a box where it should")
	-- And a sphere of radius two: a point five out is three from its surface
	assert(math.abs(Safe.Sphere(Safe.Vector3(0, 0, 0), 2):Distance(
			Safe.Vector3(0, 0, 5)) - 3) < 1e-3,
			"whitelist: a sphere does not measure to a point")

	holder:Remove()

	-- Said out loud, because the failure that cost the most here was a check
	-- that could not be told from one that never ran: an error anywhere in
	-- this block takes the whole extension down with it, and then nothing
	-- logs anything at all. A run without this line is a run where the
	-- sandbox did not load.
	log:info("whitelist: the wrapped classes round-tripped")
end

--
-- **The Starport trust colour** ([TRUST_COLOR]; user, 2026-10-03)
--
-- Any script can draw a window that looks like the client's Starport ID
-- login and ask for the password. So the client's own Starport fields
-- are drawn in a colour picked at random when the client starts, which no
-- script can read -- not from the fields (safe_classes' color getter), not
-- from the sample (never wrapped, magic_sandbox.is_hidden_ui), not from
-- the random source (the platform's, not math.random, whose state a
-- script could work back from its own draws) -- and the launcher shows
-- the sample at its top right. A login whose fields are not that colour
-- is not the client's.
--
-- simplified: twelve hues at two brightnesses, which a person tells apart
-- at a glance; a script guessing is right one time in 24. More colours
-- are more guesses to make and fewer a person can name.
local trust_rgb
do
	local b = buildat.random_bytes(2)
	local hue = (b:byte(1) % 12) / 12
	-- Dark enough under white text either way
	local v = (b:byte(2) % 2 == 0) and 0.4 or 0.6
	-- HSV with full saturation to RGB
	local i = math.floor(hue * 6)
	local f = hue * 6 - i
	local p, q, t = 0, v * (1 - f), v * f
	local rgb = ({{v, t, p}, {q, v, p}, {p, v, t}, {p, q, v}, {t, p, v},
			{v, p, q}})[i % 6 + 1]
	trust_rgb = {rgb[1], rgb[2], rgb[3]}
end

-- The colour, to the client's own code: never in Safe
local function trust_color()
	return trust_rgb[1], trust_rgb[2], trust_rgb[3]
end

-- **The trust code** ([TRUST_CODE]; user, 2026-10-05): three characters
-- stamped small in the overlay's bottom left, picked like the colour, so a
-- look-alike overlay in a game has 1 in 32768 of getting it right. No
-- 0, O, 1 or I; re-drawn if it spells a word on the list.
local trust_code
do
	local alphabet = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
	-- simplified: a few words that would be unpleasant to be shown; a
	-- longer list when someone gets one
	local blocked = {ASS = 1, FUK = 1, FUC = 1, FAG = 1, SEX = 1, KKK = 1,
			NAZ = 1, DIE = 1, CUM = 1, TIT = 1, WTF = 1, GAY = 1, SUX = 1}
	repeat
		local b = buildat.random_bytes(3)
		local c = {}
		for i = 1, 3 do
			local n = b:byte(i) % 32 + 1
			c[i] = alphabet:sub(n, n)
		end
		trust_code = table.concat(c)
	until not blocked[trust_code]
end

-- The code as a small Text on a raw element of the trust colour: the
-- overlay's last line, every Starport field. Its colour is the trust
-- colour halfway to white: every trust colour is dark enough for the
-- white labels on it (user, 2026-10-05). Hidden from scripts by its
-- name (magic_sandbox.is_hidden_ui), as inside a field a script could
-- otherwise walk to it.
local function trust_code_text(parent)
	local t = parent:CreateChild("Text")
	t:SetName("__trusted_hidden_trust_code")
	t:SetFont(cache:GetResource("Font", "Fonts/Overpass-Regular.ttf"), 9)
	t.text = trust_code
	local function mix(c)
		return c + (1 - c) * 0.5
	end
	t.color = Color(mix(trust_rgb[1]), mix(trust_rgb[2]), mix(trust_rgb[3]), 1)
	return t
end

-- And in the window title (user, 2026-10-05), which no script can read
-- or set. Not on the web: the title there is the page's, the server's.
if GetPlatform() ~= "Web" then
	graphics:SetWindowTitle(graphics:GetWindowTitle() .. " [" .. trust_code .. "]")
end

-- The sample: "Starport trust color:" and a square a text row high, at the
-- top right while the launcher has the screen (not connected anywhere).
-- Made of raw elements under a hidden name, over anything a script draws
-- (theirs stop at 999).
local trust_sample = nil
local trust_sample_shown = nil
-- [ID_LINE] (user, 2026-10-03): under the colour, "Starport ID: <name>"
-- and a Log out button per ID logged in, in the same overlay -- no script
-- can draw its look-alike over it, get it or press it (its elements are
-- never wrapped, its Log out answers a raw event to a function here).
-- Rebuilt when the IDs change, looked at twice a second.
local id_rows = {}
local id_signature = nil
local id_timer = 0
local id_logouts = 0
local offer_timer = 0
local function starport_module()
	local ok, sp = pcall(require, "buildat/core/starport")
	return ok and type(sp) == "table" and sp.logged_in_ids and sp or nil
end
-- A button of the overlay: raw, its Released answered by a global
-- function of a name no script knows to call
local function overlay_button(parent, text, fn)
	local b = parent:CreateChild("Button")
	b:SetStyleAuto()
	local bt = b:CreateChild("Text")
	bt:SetStyleAuto()
	bt.text = text
	bt:SetAlignment(HA_CENTER, VA_CENTER)
	b:SetFixedSize(bt:GetWidth() + 16, math.max(20, bt:GetHeight() + 6))
	id_logouts = id_logouts + 1
	local fname = "__buildat_trust_button_" .. id_logouts
	_G[fname] = fn
	urho_SubscribeToEvent(b, "Released", fname)
	return b
end
-- [ID_OVERLAY] (user, 2026-10-04): the launcher's Starport buttons are
-- here, on the colour: "Starport ID..." and "Starport settings..." while
-- no ID is logged in; an ID's lines when one is, and the settings under
-- them.
local function open_id(sp)
	local urls = sp.starport_urls and sp.starport_urls() or {}
	if #urls == 1 then
		sp.id_login(urls[1])
	else
		sp.open_settings()
	end
end
-- [STARPORT_RECOMMENDS]: the Hearth the Starport recommends, at the
-- address client/launch_grid.lua's hearth_target makes
local function join_hearth(sp, hearth)
	local scheme, host = hearth:match("^(https?)://([^/?#]+)")
	sp.join_with_id(scheme == "https" and "https://" .. host or
			(host:find(":%d+$") and host or host .. ":80"))
end
-- **The web has no trusted overlay** (user, 2026-10-07): the page and its
-- code are the server's ([WEB_ID_TRUST]), so a colour or an ID line there
-- would vouch for nothing, and the web holds no ID session to show. Only
-- "Discuss" per Starport recommending a Hearth, at the top right.
local is_web = GetPlatform() == "Web"
local function rebuild_web_rows(hearths, sp)
	for _, r in ipairs(id_rows) do
		r:Remove()
	end
	id_rows = {}
	local y = 8
	for _, h in ipairs(hearths) do
		local r = ui.root:CreateChild("UIElement")
		r:SetName("__trusted_hidden_id_" .. #id_rows + 1)
		r.defaultStyle = cache:GetResource("XMLFile",
				"ui_utils/res/style.xml")
		r.priority = 2001
		r:SetLayout(LM_HORIZONTAL, 8, IntRect(0, 0, 0, 0))
		r:SetAlignment(HA_RIGHT, VA_TOP)
		local host = #hearths > 1 and h.url:match("^%a+://([^/]+)")
		local b = overlay_button(r, "Discuss" ..
				(host and (" (" .. host .. ")") or ""),
				function() join_hearth(sp, h.hearth) end)
		r:SetPosition(-8, y)
		y = y + b:GetHeight() + 4
		r.visible = trust_sample_shown == true
		id_rows[#id_rows + 1] = r
	end
end
local function rebuild_id_rows(ids, sp)
	for _, r in ipairs(id_rows) do
		r:Remove()
	end
	id_rows = {}
	local several = #ids > 1
	-- Each line its own element on the root, right-aligned under the one
	-- before: a column of them stretched every line to the widest, and
	-- the colour's line went across the screen. **The colour is behind
	-- the lines** (user): one rectangle of it reaching the extents of
	-- all of them.
	local y = trust_sample:GetPosition().y
	local function line(i)
		local r = ui.root:CreateChild("UIElement")
		r:SetName("__trusted_hidden_id_" .. i)
		r.defaultStyle = trust_sample.defaultStyle
		r.priority = 2001
		r:SetLayout(LM_HORIZONTAL, 8, IntRect(0, 0, 0, 0))
		r:SetAlignment(HA_RIGHT, VA_TOP)
		return r
	end
	local function place(r, b)
		r:SetPosition(-8, y)
		y = y + math.max(r:GetHeight(), b:GetHeight()) + 4
		r.visible = trust_sample_shown == true
		id_rows[#id_rows + 1] = r
	end
	local function settings(r)
		return overlay_button(r, "Starport settings...", function()
			sp.open_settings()
		end)
	end
	for i, id in ipairs(ids) do
		local r = line(i)
		local t = r:CreateChild("Text")
		t:SetStyleAuto()
		local host = id.url:match("^%a+://([^/]+)") or id.url
		t.text = "Starport ID: " .. id.name .. (several and (" (" .. host .. ")") or "")
		t:SetVerticalAlignment(VA_CENTER)
		-- A gap of its own, as the colour's line has
		r:CreateChild("UIElement"):SetFixedSize(10, 4)
		local url = id.url
		local hearth = sp.recommended_hearth and sp.recommended_hearth(url)
		if hearth then
			-- **In a game it leaves first** ([OVERLAY_DISCUSS]): a join
			-- from inside one left luanti_client running, killed a local
			-- server into "The server exited", or did nothing
			local label = __buildat_discuss_label and __buildat_discuss_label()
			overlay_button(r, label or "Discuss", function()
				if not label then
					join_hearth(sp, hearth)
				elseif not __buildat_discuss_from_overlay(hearth) then
					log:warning("overlay: Discuss could not leave the game")
				end
			end)
		end
		local b = overlay_button(r, "Log out", function()
			sp.log_out(url)
			id_signature = nil -- rebuilt at the next look
			id_timer = 1
		end)
		place(r, b)
	end
	local r = line(#ids + 1)
	-- The code at the bottom left, the last line's first element, in the
	-- room left of its buttons when a line above is wider.
	-- simplified: with no ID logged in the last line is the only one and
	-- the code widens it; a corner of its own when that is not wanted
	trust_code_text(r):SetVerticalAlignment(VA_BOTTOM)
	-- Pushes the buttons to the right edge, under the line above
	local gap = r:CreateChild("UIElement")
	gap:SetFixedSize(0, 1)
	if #ids == 0 then
		overlay_button(r, "Starport ID...", function() open_id(sp) end)
	end
	place(r, settings(r))
	local pad = 4
	local w = 0
	for _, x in ipairs(id_rows) do
		w = math.max(w, x:GetWidth())
	end
	gap:SetFixedSize(w - r:GetWidth(), 1)
	local top = trust_sample:GetPosition().y
	local bg = ui.root:CreateChild("BorderImage")
	bg:SetName("__trusted_hidden_id_bg")
	-- Over the client's own dialogs (1000): a script's window clicked
	-- while one is up is raised to its priority (BringToFront), and a
	-- script sets 999 at most
	bg.priority = 2000
	bg:SetAlignment(HA_RIGHT, VA_TOP)
	bg:SetPosition(-8 + pad, top - pad)
	bg:SetFixedSize(w + 2 * pad, (y - 4 - top) + 2 * pad)
	bg.color = Color(trust_rgb[1], trust_rgb[2], trust_rgb[3], 1)
	bg.visible = trust_sample_shown == true
	id_rows[#id_rows + 1] = bg
end
-- **F9 shows and hides the overlay** ([TRUST_CODE]): a fake does not
-- answer the key, so it is still there after the second press. Shown
-- whenever the launcher gets the screen (the client's start, a leave),
-- where F9 acknowledges it (user, 2026-10-05); hidden on entering a game.
-- On the event's mux directly, as Safe.SubscribeToEvent's handlers never
-- get F9.
local trust_shown = true
local trust_in_game = nil
-- **A local save is a game from its start** ([LOCAL_SAVE_STARPORT]): the
-- launcher's "Starting <game>..." screen is up (launch_menu's
-- screens.lua), or the connecting screen
-- that follows it, before there is a server address to go by
local was_launching = false
local function launching_local()
	local us = package.loaded["buildat/core/uistack"]
	local stack = us and us.main and us.main.stack or {}
	local starting, connecting = false, false
	for _, e in ipairs(stack) do
		local ok, name = pcall(function() return e:GetName() end)
		if ok and type(name) == "string" then
			starting = starting or name:find(": starting_local_server", 1, true) ~= nil or
					name:find(": stopping_old_server", 1, true) ~= nil
			connecting = connecting or name:find(": connecting", 1, true) ~= nil
		end
	end
	was_launching = starting or (was_launching and connecting)
	return was_launching
end
add_global_event_handler("KeyDown", "__buildat_trust_f9", function(_, event_data)
	if event_data["Key"]:GetInt() == overlay_key and
			not event_data["Repeat"]:GetBool() then
		trust_shown = not trust_shown
		log:info("overlay key: trusted overlay " .. (trust_shown and "shown" or "hidden"))
	end
end)
Safe.SubscribeToEvent("Update", function(_, event_data)
	if trust_sample == nil and not is_web then
		trust_sample = ui.root:CreateChild("UIElement")
		trust_sample:SetName("__trusted_hidden_trust_color")
		trust_sample.defaultStyle = cache:GetResource("XMLFile",
				"ui_utils/res/style.xml")
		trust_sample:SetLayout(LM_HORIZONTAL, 6, IntRect(0, 0, 0, 0))
		trust_sample:SetAlignment(HA_RIGHT, VA_TOP)
		trust_sample:SetPosition(-8, 8)
		trust_sample.priority = 2000
		local line = trust_sample
		local label = line:CreateChild("Text")
		label:SetStyleAuto()
		label.text = "Starport trust color: "
		local row = math.max(12, label.rowHeight)
		-- Two thirds of a text row high and twice as wide (user), on the
		-- row's middle
		local h = math.floor(row * 2 / 3 + 0.5)
		-- A gap of its own: the layout's spacing left none here
		line:CreateChild("UIElement"):SetFixedSize(8, h)
		local swatch = line:CreateChild("BorderImage")
		swatch:SetFixedSize(2 * h, h)
		swatch:SetVerticalAlignment(VA_CENTER)
		swatch.color = Color(trust_rgb[1], trust_rgb[2], trust_rgb[3], 1)
	end
	-- No value at all when not connected, which tostring() refuses
	local address = __buildat_server_address()
	-- **A game with no Buildat server is a game too**
	-- ([OVERLAY_IN_LUANTI]): luanti_client's connection is its own, and
	-- it says it has a world up through ui_utils.set_in_game, which the
	-- error dialogs read as well (client/sandbox.lua)
	local uu = package.loaded["buildat/extension/ui_utils"]
	local in_game = address ~= nil or (uu ~= nil and uu.in_app == true) or
			launching_local()
	if in_game ~= trust_in_game then
		trust_in_game = in_game
		trust_shown = not trust_in_game
	end
	local show = trust_shown
	-- [STARPORT_RECOMMENDS]: new Aittas are offered on the launcher's
	-- screen only, never over a game; a newer version too ([VERSION_CHECK])
	if not trust_in_game then
		offer_timer = offer_timer + (event_data and
				event_data:GetFloat("TimeStep") or 0)
		if offer_timer >= 0.5 then
			offer_timer = 0
			local sp = starport_module()
			if sp and sp.offer_aittas then
				sp.offer_aittas()
			end
			if sp and sp.offer_version then
				sp.offer_version()
			end
		end
	end
	-- **The overlay open in a game frees the mouse** (user, 2026-10-07):
	-- the cursor shown and the game's mouse look still (GetMouseMove reads
	-- nought), given back as it closes
	local open = show and trust_in_game == true
	if open ~= mouse.overlay_open then
		mouse.overlay_open = open
		if open then
			mouse.saved_mode = input:GetMouseMode()
			input:SetMouseChangeReason("the overlay open")
			input:SetMouseMode(MM_FREE)
			input:SetMouseVisible(true)
		elseif mouse.hide_wanted then
			input:SetMouseChangeReason("the overlay closed")
			input:SetMouseMode(mouse.saved_mode or MM_ABSOLUTE)
			input:SetMouseVisible(false)
		end
	end
	if show ~= trust_sample_shown then
		trust_sample_shown = show
		-- Said when it changes ([TRUST_OVERLAY_LEAVE]): the sample gone
		-- after a leave was the user's report, and this is the first
		-- thing to read
		log:info("trust colour sample " .. (show and "shown" or "hidden") ..
				" (server address " .. tostring(address) .. ", in game " ..
				tostring(trust_in_game) .. ")")
	end
	-- The colour's own line only until the starport extension is there
	-- to build the buttons on the colour
	if trust_sample then
		trust_sample.visible = show and #id_rows == 0
	end
	for _, r in ipairs(id_rows) do
		r.visible = show
	end
	if show then
		id_timer = id_timer + (event_data and event_data:GetFloat("TimeStep") or 0)
		if id_timer >= 0.5 or id_signature == nil then
			id_timer = 0
			local sp = starport_module()
			if is_web then
				local hearths, sig = {}, {}
				for _, url in ipairs(sp and sp.starport_urls and
						sp.starport_urls() or {}) do
					local h = sp.recommended_hearth and sp.recommended_hearth(url)
					if h then
						hearths[#hearths + 1] = {url = url, hearth = h}
						sig[#sig + 1] = url .. "|" .. h
					end
				end
				sig = table.concat(sig, "\n")
				if sig ~= id_signature and sp then
					id_signature = sig
					rebuild_web_rows(hearths, sp)
					log:info("trusted overlay: " .. #hearths .. " Discuss button(s)")
				end
				return
			end
			local ids = sp and sp.logged_in_ids() or {}
			local sig = {(sp and "" or "no extension") .. "|" ..
					tostring(__buildat_discuss_label and __buildat_discuss_label())}
			for _, id in ipairs(ids) do
				sig[#sig + 1] = id.url .. "|" .. id.name .. "|" ..
						tostring(sp.recommended_hearth and
						sp.recommended_hearth(id.url))
			end
			sig = table.concat(sig, "\n")
			if sig ~= id_signature and sp then
				id_signature = sig
				rebuild_id_rows(ids, sp)
				log:info("trusted overlay: " .. #ids .. " Starport ID line(s)")
			end
		end
	end
end)

--
-- Create the final interface
--

local M = {}
M.trust_color = trust_color
M.trust_code_text = trust_code_text
M.drop_sandbox_handlers = drop_sandbox_handlers
M.drop_handlers_of = drop_handlers_of
M.safe = Safe
M.unsafe = Unsafe

return M
-- vim: set noet ts=4 sw=4:
