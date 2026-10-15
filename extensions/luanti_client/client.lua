-- Buildat: extension/luanti_client/client.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- Luanti's client side of the login, on top of connection.lua:
--
--   client -> INIT (name, protocol range)
--   server -> HELLO (protocol version, which auth mechanisms it takes)
--   client -> SRP_BYTES_A or FIRST_SRP (a new player registers a verifier)
--   server -> SRP_BYTES_S_B (salt and B)
--   client -> SRP_BYTES_M (the proof)
--   server -> AUTH_ACCEPT, and then the definitions and the media
--   client -> INIT2, and CLIENT_READY once it has what it needs
--
-- Commands that are not handled yet are counted and logged; see
-- doc/luanti_client.txt for what is left.

local serialize = buildat.run_extension_file("serialize.lua")
local connection = buildat.run_extension_file("connection.lua")
local srp = buildat.run_extension_file("srp.lua")
local nodemeta = buildat.run_extension_file("nodemeta.lua")
local inventory = buildat.run_extension_file("inventory.lua")
local hud = buildat.run_extension_file("res/hud.lua")
local sounds = buildat.run_extension_file("res/sounds.lua")
local particles = buildat.run_extension_file("res/particles.lua")

local M = {}

-- What this client tells the server it is
local SER_FMT_VER_HIGHEST_READ = 29
local CLIENT_PROTOCOL_VERSION_MIN = 37
local LATEST_PROTOCOL_VERSION = 52
local FORMSPEC_API_VERSION = 8
-- The Luanti version this claims to be, which is the newest one that speaks
-- the protocol above: a game that branches on the version then takes the
-- path this implements, where claiming an older one would send it down a
-- path for a client that no longer exists. The string beside it is what
-- Luanti puts its full version in, and a server shows it in a player list.
-- The buildat version goes in it ([LICENSE_DUAL]'s first courtesy), so
-- an operator reading a player list sees "buildat 0.4.19 luanti_client"
-- rather than a bare name and knows what is connecting
local VERSION = {major = 5, minor = 17, patch = 0,
		hash = "buildat "..buildat.version()..
				" luanti_client"}

-- The language the player reads, which a game asks for through
-- get_player_information().lang_code -- this game's craft guide, creative
-- inventory and doc mod all do. Luanti sends the language its own UI is in;
-- the nearest thing here is what the environment says.
--
-- What comes out is the two-letter code a Luanti mod expects, out of a POSIX
-- locale name: "fi_FI.UTF-8" is "fi", "en_GB:en" is "en", and "C" or
-- "POSIX" is no language at all rather than "c".
function M.language_code(locale)
	locale = tostring(locale or "")
	if locale == "C" or locale == "POSIX" then
		return ""
	end
	return (locale:match("^(%a%a)") or ""):lower()
end

local function environment_language()
	return M.language_code(buildat.get_locale())
end

local TOSERVER = {
	INIT          = 0x02,
	INIT2         = 0x11,
	PLAYERPOS     = 0x23,
	GOTBLOCKS     = 0x24,
	DELETEDBLOCKS = 0x25,
	INVENTORY_ACTION = 0x31,
	CHAT_MESSAGE  = 0x32,
	DAMAGE        = 0x35,
	INTERACT      = 0x39,
	NODEMETA_FIELDS = 0x3b,
	INVENTORY_FIELDS = 0x3c,
	REQUEST_MEDIA = 0x40,
	CLIENT_READY  = 0x43,
	FIRST_SRP     = 0x50,
	SRP_BYTES_A   = 0x51,
	SRP_BYTES_M   = 0x52,
}

-- The channel each command goes on, and whether it is sent reliably; from
-- Luanti's serverCommandFactoryTable
local TOSERVER_DELIVERY = {
	[TOSERVER.INIT]          = {1, false},
	[TOSERVER.INIT2]         = {1, true},
	[TOSERVER.PLAYERPOS]     = {0, false},
	[TOSERVER.GOTBLOCKS]     = {2, true},
	[TOSERVER.DELETEDBLOCKS] = {2, true},
	[TOSERVER.INVENTORY_ACTION] = {0, true},
	[TOSERVER.CHAT_MESSAGE]  = {0, true},
	[TOSERVER.INTERACT]      = {0, true},
	[TOSERVER.DAMAGE]        = {0, true},
	[TOSERVER.NODEMETA_FIELDS] = {0, true},
	[TOSERVER.INVENTORY_FIELDS] = {0, true},
	[TOSERVER.REQUEST_MEDIA] = {1, true},
	[TOSERVER.CLIENT_READY]  = {1, true},
	[TOSERVER.FIRST_SRP]     = {1, true},
	[TOSERVER.SRP_BYTES_A]   = {1, true},
	[TOSERVER.SRP_BYTES_M]   = {1, true},
}

-- What TOSERVER_INTERACT can say, from Luanti's InteractAction
M.INTERACT_START_DIGGING = 0
M.INTERACT_STOP_DIGGING = 1
M.INTERACT_DIGGING_COMPLETED = 2
M.INTERACT_PLACE = 3
M.INTERACT_USE = 4
M.INTERACT_ACTIVATE = 5

-- Luanti's PlayerControl bits, which PLAYERPOS carries; see
-- PlayerControl::getKeysPressed() in its player.cpp
M.KEY_UP = 1
M.KEY_DOWN = 2
M.KEY_LEFT = 4
M.KEY_RIGHT = 8
M.KEY_JUMP = 16
M.KEY_AUX1 = 32
M.KEY_SNEAK = 64
M.KEY_DIG = 128
M.KEY_PLACE = 256
M.KEY_ZOOM = 512

-- The order TOCLIENT_MOVEMENT's twelve floats come in
local MOVEMENT_FIELDS = {
	"acceleration_default", "acceleration_air", "acceleration_fast",
	"speed_walk", "speed_crouch", "speed_fast", "speed_climb", "speed_jump",
	"liquid_fluidity", "liquid_fluidity_smooth", "liquid_sink", "gravity",
}

local TOCLIENT = {
	HELLO          = 0x02,
	AUTH_ACCEPT    = 0x03,
	ACCESS_DENIED  = 0x0A,
	BLOCKDATA      = 0x20,
	NODEMETA_CHANGED = 0x59,
	ADDNODE        = 0x21,
	REMOVENODE     = 0x22,
	TIME_OF_DAY    = 0x29,
	MOVE_PLAYER    = 0x34,
	MOVEMENT       = 0x45,
	CAMERA         = 0x48,
	MEDIA          = 0x38,
	NODEDEF        = 0x3A,
	ANNOUNCE_MEDIA = 0x3C,
	SET_SKY        = 0x4F,
	ACTIVE_OBJECT_REMOVE_ADD = 0x31,
	ACTIVE_OBJECT_MESSAGES = 0x32,
	CHAT_MESSAGE   = 0x2F,
	HP             = 0x33,
	BREATH         = 0x4E,
	INVENTORY      = 0x27,
	ITEMDEF        = 0x3D,
	INVENTORY_FORMSPEC = 0x42,
	DETACHED_INVENTORY = 0x43,
	SHOW_FORMSPEC  = 0x44,
	FORMSPEC_PREPEND = 0x61,
	HUDADD         = 0x49,
	HUDRM          = 0x4A,
	HUDCHANGE      = 0x4B,
	HUD_SET_FLAGS  = 0x4C,
	HUD_SET_PARAM  = 0x4D,
	PLAY_SOUND     = 0x3F,
	STOP_SOUND     = 0x40,
	PRIVILEGES     = 0x41,
	SPAWN_PARTICLE = 0x46,
	ADD_PARTICLESPAWNER = 0x47,
	DELETE_PARTICLESPAWNER = 0x53,
	SET_LIGHTING = 0x63,
	SPAWN_PARTICLE_BATCH = 0x64,
	FADE_SOUND     = 0x55,
	FOV            = 0x36,
	OVERRIDE_DAY_NIGHT_RATIO = 0x50,
	PLAYER_SPEED   = 0x2B,
	CLOUD_PARAMS   = 0x54,
	SET_SUN        = 0x5A,
	SET_MOON       = 0x5B,
	SET_STARS      = 0x5C,
	SRP_BYTES_S_B  = 0x60,
}

-- 16x16x16 nodes to a mapblock, as everywhere in Luanti
local MAP_BLOCKSIZE = 16
local NODECOUNT = MAP_BLOCKSIZE * MAP_BLOCKSIZE * MAP_BLOCKSIZE
-- Luanti's BS: one node is this many of the units positions come in
local BS = 10.0

-- Node ids that mean something to everyone, whatever the game is; from
-- Luanti's mapnode.h. Everything else needs the node definitions.
M.CONTENT_UNKNOWN = 125
M.CONTENT_AIR = 126
M.CONTENT_IGNORE = 127

-- How often the server hears where we are. It sends blocks around the last
-- position it heard, so nothing arrives until this does.
local PLAYERPOS_INTERVAL = 0.1
-- How many blocks out to ask for. The server adds one and then clips this to
-- its own max_block_send_distance.
local WANTED_RANGE_BLOCKS = 6
-- The field of view we claim, in radians; the server culls blocks outside it
local FOV = 1.72

-- For logging what is not handled yet; from Luanti's ToClientCommand enum
local TOCLIENT_NAME = {
	[0x02] = "HELLO",
	[0x03] = "AUTH_ACCEPT",
	[0x04] = "ACCEPT_SUDO_MODE",
	[0x05] = "DENY_SUDO_MODE",
	[0x0a] = "ACCESS_DENIED",
	[0x20] = "BLOCKDATA",
	[0x21] = "ADDNODE",
	[0x22] = "REMOVENODE",
	[0x27] = "INVENTORY",
	[0x29] = "TIME_OF_DAY",
	[0x2a] = "CSM_RESTRICTION_FLAGS",
	[0x2b] = "PLAYER_SPEED",
	[0x2c] = "MEDIA_PUSH",
	[0x2f] = "CHAT_MESSAGE",
	[0x31] = "ACTIVE_OBJECT_REMOVE_ADD",
	[0x32] = "ACTIVE_OBJECT_MESSAGES",
	[0x33] = "HP",
	[0x34] = "MOVE_PLAYER",
	[0x35] = "ACCESS_DENIED_LEGACY",
	[0x36] = "FOV",
	[0x37] = "DEATHSCREEN_LEGACY",
	[0x38] = "MEDIA",
	[0x3a] = "NODEDEF",
	[0x3c] = "ANNOUNCE_MEDIA",
	[0x3d] = "ITEMDEF",
	[0x3f] = "PLAY_SOUND",
	[0x40] = "STOP_SOUND",
	[0x41] = "PRIVILEGES",
	[0x42] = "INVENTORY_FORMSPEC",
	[0x43] = "DETACHED_INVENTORY",
	[0x44] = "SHOW_FORMSPEC",
	[0x45] = "MOVEMENT",
	[0x46] = "SPAWN_PARTICLE",
	[0x47] = "ADD_PARTICLESPAWNER",
	[0x48] = "CAMERA",
	[0x49] = "HUDADD",
	[0x4a] = "HUDRM",
	[0x4b] = "HUDCHANGE",
	[0x4c] = "HUD_SET_FLAGS",
	[0x4d] = "HUD_SET_PARAM",
	[0x4e] = "BREATH",
	[0x4f] = "SET_SKY",
	[0x50] = "OVERRIDE_DAY_NIGHT_RATIO",
	[0x51] = "LOCAL_PLAYER_ANIMATIONS",
	[0x52] = "EYE_OFFSET",
	[0x53] = "DELETE_PARTICLESPAWNER",
	[0x54] = "CLOUD_PARAMS",
	[0x55] = "FADE_SOUND",
	[0x56] = "UPDATE_PLAYER_LIST",
	[0x57] = "MODCHANNEL_MSG",
	[0x58] = "MODCHANNEL_SIGNAL",
	[0x59] = "NODEMETA_CHANGED",
	[0x5a] = "SET_SUN",
	[0x5b] = "SET_MOON",
	[0x5c] = "SET_STARS",
	[0x5d] = "MOVE_PLAYER_REL",
	[0x60] = "SRP_BYTES_S_B",
	[0x61] = "FORMSPEC_PREPEND",
	[0x62] = "MINIMAP_MODES",
	[0x63] = "SET_LIGHTING",
	[0x64] = "SPAWN_PARTICLE_BATCH",
}

-- What the server means by the code in an ACCESS_DENIED, from Luanti's
-- accessDeniedStrings[]. A denial that comes with a string of its own uses
-- that instead; that is what reason 10 is for.
local DENY_REASON = {
	[0] = "invalid password",
	[1] = "the client sent something the server did not expect",
	[2] = "the server is in singleplayer mode",
	[3] = "the client's version is not supported",
	[4] = "the player name has disallowed characters in it",
	[5] = "the player name is not allowed",
	[6] = "too many users",
	[7] = "empty passwords are disallowed",
	[8] = "another client is connected with this name",
	[9] = "internal server error",
	[10] = "no reason given",
	[11] = "the server is shutting down",
	[12] = "the server hit an internal error",
}

local AUTH_MECHANISM = {
	LEGACY_PASSWORD = 1,
	SRP             = 2,
	FIRST_SRP       = 4,
}

-- Parses one BLOCKDATA payload, the u16 command already read off it.
--
-- At serialization version 29 the whole block is one zstd frame, and inside it
--   u8 flags | u16 lighting_complete | u8 content_width | u8 params_width
--   | 4096 u16be param0 | 4096 u8 param1 | 4096 u8 param2 | node metadata
-- and after the frame a u8 of MapBlock::serializeNetworkSpecific. Blocks of one
-- node are expanded before being sent, so the bulk data is always 16384 bytes.
--
-- The three parameter arrays are handed on as they came, because that is what
-- buildat.pack_voxel_volume() takes. Node index order is x fastest, then y,
-- then z, which is also PolyVox's.
local function parse_blockdata(data)
	local r = serialize.reader(data)
	local x, y, z = r:v3s16()
	local raw = buildat.decompress(r:rest(), "zstd")
	local b = serialize.reader(raw)
	local flags = b:u8()
	local lighting_complete = b:u16()
	local content_width = b:u8()
	local params_width = b:u8()
	if content_width ~= 2 or params_width ~= 2 then
		error("luanti_client: mapblock has content_width "..content_width..
				" and params_width "..params_width..", expected 2 and 2")
	end
	local block = {
		x = x, y = y, z = z,
		is_underground = flags % 2 == 1,
		lighting_complete = lighting_complete,
		param0 = b:raw(NODECOUNT * 2),
		param1 = b:raw(NODECOUNT),
		param2 = b:raw(NODECOUNT),
	}
	-- What hangs off the voxels in it: a chest's contents, a sign's text.
	-- Keyed by the index into the block. A block whose metadata cannot be
	-- read is still a block: the geometry is worth more than the chests.
	local ok, meta = pcall(nodemeta.parse, b, inventory, false)
	block.meta = ok and meta or {}
	block.meta_error = (not ok) and tostring(meta) or nil
	return block
end

-- new(socket, options, log): options.name, options.password and
-- options.on_status(text), which is called with what is going on.
-- client.on_command(command, data) gets every command that arrives.
function M.new(socket, options, log)
	local self = {
			state = "connecting",
			protocol_version = nil,
			unhandled = {}, -- command -> how many arrived
			on_status = options.on_status,
			on_command = nil,
			-- on_block(block) for each mapblock that arrives; see
			-- parse_blockdata() for what a block holds
			on_block = nil,
			-- on_node(x, y, z, param0, param1, param2) for a single node the
			-- server changed. param0 is CONTENT_AIR for a removal.
			on_node = nil,
			-- on_node_meta(entries) with the metadata a server changed,
			-- keyed by "x,y,z"; see nodemeta.lua
			on_node_meta = nil,
			-- on_nodedef(data) with the decompressed NODEDEF payload;
			-- nodedef.lua is what reads it
			on_nodedef = nil,
			-- on_itemdef(data) with the decompressed ITEMDEF payload;
			-- itemdef.lua is what reads it
			on_itemdef = nil,
			-- on_inventory(data) with the player's inventory as Luanti
			-- serializes one; inventory.lua is what reads it
			on_inventory = nil,
			-- on_detached_inventory(name, data), with data nil when the
			-- server drops the inventory
			on_detached_inventory = nil,
			-- The forms: on_inventory_formspec(spec) is the one the
			-- inventory key opens, on_show_formspec(spec, formname) one the
			-- server wants shown now, and on_formspec_prepend(spec) what
			-- goes in front of both
			on_inventory_formspec = nil,
			on_show_formspec = nil,
			on_formspec_prepend = nil,
			-- The HUD the game puts on the screen: on_hud(elements, flags,
			-- params) after every change to any of them, with the elements
			-- keyed by the server's own id. hud.lua is what reads the
			-- packets and says what the flags mean.
			on_hud = nil,
			-- The sounds: on_play_sound(id, spec) with what sounds.lua read
			-- out of PLAY_SOUND, on_stop_sound(id) and
			-- on_fade_sound(id, step, gain). The id is the server's own and
			-- is what the latter two name.
			-- on_fov(fov, is_multiplier, transition_time): what the server
			-- wants the camera's field of view to be, in degrees or as a
			-- multiple of the client's own, with zero meaning back to the
			-- client's own
			on_fov = nil,
			-- What the server says the light is whatever the time is, out of
			-- OVERRIDE_DAY_NIGHT_RATIO: 0...1, or nil for a server that has
			-- stopped overriding it. A game sets this where the sky has
			-- nothing to do with the light -- underground, in another
			-- dimension, in a cutscene.
			day_night_override = nil,
			-- on_player_speed(x, y, z): a push the server gave the player,
			-- in nodes a second, to add to whatever speed it already has
			on_player_speed = nil,
			-- The things in the sky the game describes, each with what its
			-- own packet said: on_sun(sun), on_moon(moon), on_stars(stars)
			-- and on_clouds(clouds)
			on_sun = nil,
			on_moon = nil,
			on_stars = nil,
			on_clouds = nil,
			-- on_lighting(lighting): the game's set_lighting(), see
			-- SET_LIGHTING
			on_lighting = nil,
			on_play_sound = nil,
			on_stop_sound = nil,
			on_fade_sound = nil,
			-- on_announce_media(files, remote_servers) and
			-- on_media(files, bunch, bunches); media.lua is what keeps them
			on_announce_media = nil,
			on_media = nil,
			-- on_movement(movement) with the game's movement constants, in
			-- nodes a second and nodes a second squared; player.lua's
			-- DEFAULT_MOVEMENT says what the fields are
			on_movement = nil,
			-- Where the server last put us, in nodes, and where we tell it we
			-- are. The extension moves this; see set_position().
			position = {x = 0, y = 0, z = 0},
			pitch = 0,
			yaw = 0,
			-- What we tell the server we are doing: our speed in nodes a
			-- second, and the keys as Luanti's PlayerControl bits
			speed = {x = 0, y = 0, z = 0},
			keys = 0,
			-- The things in the world that are not nodes:
			-- on_object_add(id, type, init_data), on_object_remove(id) and
			-- on_object_message(id, data). objects.lua is what reads the
			-- data and the messages.
			on_object_add = nil,
			on_object_remove = nil,
			on_object_message = nil,
			-- on_sky(sky) with what the game says the sky looks like; the
			-- colours are {r, g, b} and which ones are there depends on the
			-- type
			on_sky = nil,
			-- on_chat(text, sender, message_type) for every chat message,
			-- the server's own included; a message with no sender is one
			-- from the server rather than from a player
			on_chat = nil,
			-- How the player is doing, as the server last said: hit points
			-- out of 20, and breath out of 10 while under water
			hp = nil,
			breath = nil,
			-- The server's time of day, 0...23999, and how fast it runs.
			-- time_of_day is the last thing the server said; time_of_day_f
			-- is the same clock carried on between those, which is what
			-- anything drawing the sky wants.
			time_of_day = nil,
			time_of_day_f = nil,
			time_speed = 0,
			blocks_received = 0,
			-- Counters for the slow-frame line; see update() below
			commands_handled = 0,
			last_command_us = 0,
			last_commands = 0,
			-- Assembled commands that did not fit in a frame's budget
			commands_waiting = 0,
	}
	local name = options.name
	local password = options.password or ""
	local srp_client = nil
	local conn = connection.new(socket, log)
	self.connection = conn

	local function status(text)
		log:info(text)
		if self.on_status then
			self.on_status(text)
		end
	end

	local function send_command(command, data)
		local delivery = TOSERVER_DELIVERY[command]
		if not delivery then
			error("luanti_client: no channel known for command "..command)
		end
		local packet = serialize.writer():u16(command):raw(data or ""):data()
		conn:send(delivery[1], delivery[2], packet)
	end
	self.send_command = function(_, command, data)
		send_command(command, data)
	end

	local function send_init()
		local w = serialize.writer()
		w:u8(SER_FMT_VER_HIGHEST_READ)
		w:u16(0) -- Compression modes; never implemented
		w:u16(CLIENT_PROTOCOL_VERSION_MIN)
		w:u16(LATEST_PROTOCOL_VERSION)
		w:string(name)
		send_command(TOSERVER.INIT, w:data())
		self.state = "init_sent"
		status("Sent INIT as "..name)
	end

	-- The mechanisms come as a bit mask; no bit operations in plain Lua 5.1
	local function has_mechanism(mechanisms, mechanism)
		return mechanisms % (mechanism * 2) >= mechanism
	end

	local function start_auth(mechanisms)
		if has_mechanism(mechanisms, AUTH_MECHANISM.SRP) then
			-- A player the server knows: prove we know the password
			srp_client = srp.client(name, name:lower(), password)
			local w = serialize.writer()
			w:string(srp_client:bytes_A())
			w:u8(1) -- Based on the password itself, not the legacy hash
			send_command(TOSERVER.SRP_BYTES_A, w:data())
			self.state = "srp_a_sent"
			status("Logging in as "..name)
		elseif has_mechanism(mechanisms, AUTH_MECHANISM.FIRST_SRP) then
			-- A new player: register a verifier for the password
			local salt, verifier = srp.create_verifier(name:lower(), password)
			local w = serialize.writer()
			w:string(salt)
			w:string(verifier)
			w:u8(password == "" and 1 or 0)
			send_command(TOSERVER.FIRST_SRP, w:data())
			self.state = "first_srp_sent"
			status("Registering "..name)
		else
			status("The server offers no authentication this client can do "..
					"(mechanisms "..mechanisms..")")
			self.state = "failed"
			fail("The server offers no way to log in\n"..
					"that this client can do.\n"..
					"(mechanisms "..mechanisms..")", true)
		end
	end

	-- Why the session ended, in words, or nil while it has not. A denial and
	-- the disconnection that follows it arrive together -- the server sends
	-- ACCESS_DENIED and closes -- and the denial is the one worth showing,
	-- which is what specific says. self:update() is what hands it over, once
	-- everything that arrived has been looked at.
	self.failure = nil
	local failure_specific = false
	local failure_told = false
	-- When this client was made, which is what the silence is measured from
	-- until the first datagram arrives
	local started_us = buildat.get_time_us()

	local function fail(text, specific)
		if failure_specific and not specific then
			return
		end
		self.failure = text
		failure_specific = specific or failure_specific
	end

	-- Positions of blocks that have arrived and not been acknowledged yet
	local gotblocks = {}

	local handlers = {}

	-- Definitions and media were zlib until protocol 48 and are zstd from
	-- there on; see Client::handleCommand_NodeDef.
	local function defs_compression(self)
		return self.protocol_version >= 48 and "zstd" or "zlib"
	end

	handlers[TOCLIENT.HELLO] = function(r)
		local serialization_version = r:u8()
		r:u16() -- Compression modes; never implemented
		self.protocol_version = r:u16()
		local auth_mechanisms = r:u32()
		status("Server speaks protocol "..self.protocol_version..
				" (serialization "..serialization_version..")")
		if self.protocol_version < CLIENT_PROTOCOL_VERSION_MIN then
			status("The server is too old for this client")
			self.state = "failed"
			fail("The server speaks protocol "..self.protocol_version..
					",\nand this client needs "..
					CLIENT_PROTOCOL_VERSION_MIN.." or newer.", true)
			return
		end
		-- Only serialization version 29 is parsed; older mapblocks compress
		-- their pieces separately and this client has no branch for that
		if serialization_version ~= SER_FMT_VER_HIGHEST_READ then
			status("The server serializes mapblocks as version "..
					serialization_version..", this client reads "..
					SER_FMT_VER_HIGHEST_READ)
			self.state = "failed"
			fail("The server serializes its map as version "..
					serialization_version..",\nand this client reads only "..
					SER_FMT_VER_HIGHEST_READ..".", true)
			return
		end
		start_auth(auth_mechanisms)
	end

	handlers[TOCLIENT.SRP_BYTES_S_B] = function(r)
		local salt = r:string()
		local B = r:string()
		if not srp_client then
			status("Got an SRP challenge without having asked for one")
			return
		end
		local proof = srp_client:process_challenge(salt, B)
		if not proof then
			status("The server's SRP challenge failed the safety check")
			self.state = "failed"
			fail("The server's part of the login failed\n"..
					"SRP's own safety check.\n"..
					"Nothing was sent to it.", true)
			return
		end
		send_command(TOSERVER.SRP_BYTES_M, serialize.writer():string(proof)
				:data())
		self.state = "srp_m_sent"
		-- What the server says next is either AUTH_ACCEPT or a denial, and
		-- an "invalid password" denial means this proof is what it did not
		-- like: the line is here so that a log says how far the login got
		status("Sent the password proof")
	end

	handlers[TOCLIENT.AUTH_ACCEPT] = function(r)
		-- v3f unused, u64 map seed, f1000 send interval, u32 sudo mechanisms
		self.state = "authenticated"
		status("Logged in")
		send_command(TOSERVER.INIT2,
				serialize.writer():string(environment_language()):data())
	end

	-- CLIENT_READY is what makes the server spawn the player, and it waits for
	-- the definitions. Their contents are not used yet.
	local got_itemdef, got_nodedef, client_ready_sent = false, false, false

	local function maybe_send_client_ready()
		if client_ready_sent or not (got_itemdef and got_nodedef) then
			return
		end
		client_ready_sent = true
		self:send_client_ready()
		self.state = "spawning"
	end

	handlers[TOCLIENT.ITEMDEF] = function(r)
		local data = buildat.decompress(r:longstring(), defs_compression(self))
		got_itemdef = true
		if self.on_itemdef then
			self.on_itemdef(data)
		end
		maybe_send_client_ready()
	end

	-- The player's own inventory, whenever the server changes it. At
	-- protocol 52 it is a long string with a flag after it; older servers put
	-- the inventory in the rest of the packet.
	handlers[TOCLIENT.INVENTORY] = function(r)
		local data = self.protocol_version > 51 and r:longstring() or r:rest()
		if self.on_inventory then
			self.on_inventory(data)
		end
	end

	-- The form the inventory key opens, which a game replaces whenever it
	-- likes: this one swaps in a creative inventory once it knows the player
	-- is in creative mode.
	handlers[TOCLIENT.INVENTORY_FORMSPEC] = function(r)
		if self.on_inventory_formspec then
			self.on_inventory_formspec(r:longstring())
		end
	end

	-- What the server lets this player do. What this is for is saying why
	-- something was refused: a client that flies without the privilege is
	-- pulled back by the server's own movement check and nothing says why.
	handlers[TOCLIENT.PRIVILEGES] = function(r)
		local privs = {}
		for _ = 1, r:u16() do
			privs[r:string()] = true
		end
		self.privileges = privs
		if self.on_privileges then
			self.on_privileges(privs)
		end
	end

	-- What goes in front of every formspec the game sends, which is where it
	-- puts the styling all of its forms share
	handlers[TOCLIENT.FORMSPEC_PREPEND] = function(r)
		if self.on_formspec_prepend then
			self.on_formspec_prepend(r:string())
		end
	end

	-- A form the server wants shown now, and the name to send its fields
	-- back under
	handlers[TOCLIENT.SHOW_FORMSPEC] = function(r)
		local spec = r:longstring()
		local name = r:string()
		if self.on_show_formspec then
			self.on_show_formspec(spec, name)
		end
	end

	-- The game's own HUD. The elements are kept here rather than in the
	-- extension because HUDCHANGE names one field of one of them, so
	-- somebody has to hold the rest; what the extension gets is the whole
	-- lot after every change.
	self.hud_elements = {}
	self.hud_flags = hud.FLAGS_DEFAULT
	self.hud_params = {}

	local function hud_changed()
		if self.on_hud then
			self.on_hud(self.hud_elements, self.hud_flags, self.hud_params)
		end
	end

	-- TOCLIENT_CAMERA: which camera modes the key may reach -- 0 any, 1
	-- first, 2 third, 3 third front ([THIRD_PERSON])
	self.camera_mode_allowed = 0
	handlers[TOCLIENT.CAMERA] = function(r)
		self.camera_mode_allowed = r:u8()
	end

	handlers[TOCLIENT.HUDADD] = function(r)
		local id, e = hud.read_add(r, self.protocol_version)
		self.hud_elements[id] = e
		hud_changed()
	end

	handlers[TOCLIENT.HUDRM] = function(r)
		self.hud_elements[r:u32()] = nil
		hud_changed()
	end

	handlers[TOCLIENT.HUDCHANGE] = function(r)
		local id, field, value = hud.read_change(r, self.protocol_version)
		local e = self.hud_elements[id]
		-- A stat this does not know leaves the element as it was, which is
		-- what Luanti does with one too
		if e and field then
			e[field] = value
			hud_changed()
		end
	end

	handlers[TOCLIENT.HUD_SET_FLAGS] = function(r)
		local flags = r:u32()
		local mask = r:u32()
		self.hud_flags = hud.apply_flags(self.hud_flags, flags, mask)
		hud_changed()
	end

	handlers[TOCLIENT.HUD_SET_PARAM] = function(r)
		local param, value = hud.read_param(r)
		if value ~= nil then
			self.hud_params[param] = value
			hud_changed()
		end
	end

	-- The transition time came in 5.3, so an older server stops after the
	-- multiplier flag
	handlers[TOCLIENT.FOV] = function(r)
		local fov = r:f32()
		local is_multiplier = r:u8() ~= 0
		local transition_time = 0
		if r:remaining() >= 4 then
			transition_time = r:f32()
		end
		if self.on_fov then
			self.on_fov(fov, is_multiplier, transition_time)
		end
	end

	handlers[TOCLIENT.PLAYER_SPEED] = function(r)
		local x, y, z = r:v3f()
		if self.on_player_speed then
			self.on_player_speed(x / BS, y / BS, z / BS)
		end
	end

	handlers[TOCLIENT.OVERRIDE_DAY_NIGHT_RATIO] = function(r)
		local do_override = r:u8() ~= 0
		-- In thousandths, which is Luanti's own unit for it
		local ratio = r:u16()
		self.day_night_override = do_override and
				math.min(math.max(ratio / 1000, 0), 1) or nil
	end

	-- Particles. A spawner is a description the client runs itself until the
	-- server deletes it or its time is up; a single particle is one of them
	-- already picked. SPAWN_PARTICLE_BATCH is a zstd frame of length-prefixed
	-- single particles, which is how a game sends a hundred of them at once.
	handlers[TOCLIENT.ADD_PARTICLESPAWNER] = function(r)
		local p, why = particles.parse_spawner(r, self.protocol_version)
		if not p then
			log:verbose("particles: spawner dropped: "..tostring(why))
			return
		end
		if self.on_particle_spawner then
			self.on_particle_spawner(p.server_id, p)
		end
	end

	handlers[TOCLIENT.DELETE_PARTICLESPAWNER] = function(r)
		local id = r:u32()
		if self.on_particle_spawner then
			self.on_particle_spawner(id, nil)
		end
	end

	handlers[TOCLIENT.SPAWN_PARTICLE] = function(r)
		if self.on_particle then
			self.on_particle(particles.parse_particle(r,
					self.protocol_version))
		end
	end

	handlers[TOCLIENT.SPAWN_PARTICLE_BATCH] = function(r)
		if not self.on_particle then
			return
		end
		local inner = serialize.reader(
				buildat.decompress(r:longstring(), "zstd"))
		while inner:remaining() >= 4 do
			local one = serialize.reader(inner:longstring())
			self.on_particle(particles.parse_particle(one,
					self.protocol_version))
		end
	end

	handlers[TOCLIENT.PLAY_SOUND] = function(r)
		local id, spec = sounds.read_play(r)
		if self.on_play_sound then
			self.on_play_sound(id, spec)
		end
	end

	handlers[TOCLIENT.STOP_SOUND] = function(r)
		if self.on_stop_sound then
			self.on_stop_sound(sounds.read_stop(r))
		end
	end

	handlers[TOCLIENT.FADE_SOUND] = function(r)
		local id, step, gain = sounds.read_fade(r)
		if self.on_fade_sound then
			self.on_fade_sound(id, step, gain)
		end
	end

	-- An inventory that is not the player's own: a creative list, a trash
	-- can, whatever a game detaches. Same serialization as the player's.
	handlers[TOCLIENT.DETACHED_INVENTORY] = function(r)
		local name = r:string()
		local keep = r:u8() ~= 0
		if not keep then
			if self.on_detached_inventory then
				self.on_detached_inventory(name, nil)
			end
			return
		end
		r:skip(2) -- Used to be the length of what follows
		if self.on_detached_inventory then
			self.on_detached_inventory(name, r:rest())
		end
	end

	-- What the sky looks like, which a game sets and changes.
	--
	-- Only the colours are read. A "regular" sky has a colour for the sky and
	-- one for the horizon at each of day, dawn and night; anything else --
	-- "skybox" with six textures, "plain" with one colour -- has the
	-- background colour and that is all.
	-- {r, g, b, a}, each 0...255. The alpha is on the wire for every colour
	-- and means something for some of them -- a cloud's is how opaque the
	-- layer is -- so it is handed on; a caller that does not want it reads
	-- the first three.
	local function read_color(r)
		local argb = r:u32()
		return {math.floor(argb / 0x10000) % 0x100,
				math.floor(argb / 0x100) % 0x100, argb % 0x100,
				math.floor(argb / 0x1000000) % 0x100}
	end

	handlers[TOCLIENT.SET_SKY] = function(r)
		local sky = {}
		sky.bgcolor = read_color(r)
		sky.type = r:string()
		sky.clouds = r:u8() ~= 0
		-- What the sun and the moon paint the horizon around them with
		sky.sun_tint = read_color(r)
		sky.moon_tint = read_color(r)
		r:string() -- fog_tint_type
		if sky.type == "skybox" then
			sky.textures = {}
			for _ = 1, r:u16() do
				sky.textures[#sky.textures + 1] = r:string()
			end
		elseif sky.type == "regular" then
			sky.day_sky = read_color(r)
			sky.day_horizon = read_color(r)
			sky.dawn_sky = read_color(r)
			sky.dawn_horizon = read_color(r)
			sky.night_sky = read_color(r)
			sky.night_horizon = read_color(r)
			sky.indoors = read_color(r)
		end
		-- The tail Luanti 5.9+ appends; an older server's packet ends here.
		-- fog_start is what the reference fixture turns the fog off with
		-- (0.99: see builtin/luanti/test/reference_shots/runner.lua), so it is read as of 2026-09-17.
		if r:remaining() >= 4 + 2 + 4 + 4 then
			sky.body_orbit_tilt = r:f32()
			sky.fog_distance = r:s16()
			sky.fog_start = r:f32()
			sky.fog_color = read_color(r)
		end
		if r:remaining() >= 1 then
			sky.auto_dim_skybox = r:u8() ~= 0
		end
		if self.on_sky then
			self.on_sky(sky)
		end
	end

	-- The objects that went away and the ones that arrived
	-- What the sun, the moon and the stars look like. A game turns one off
	-- as often as it changes one: a dimension with no sky has none of them.
	handlers[TOCLIENT.SET_SUN] = function(r)
		local sun = {}
		sun.visible = r:u8() ~= 0
		sun.texture = r:string()
		sun.tonemap = r:string()
		sun.sunrise = r:string()
		sun.sunrise_visible = r:u8() ~= 0
		sun.scale = r:f32()
		if self.on_sun then
			self.on_sun(sun)
		end
	end

	handlers[TOCLIENT.SET_MOON] = function(r)
		local moon = {}
		moon.visible = r:u8() ~= 0
		moon.texture = r:string()
		moon.tonemap = r:string()
		moon.scale = r:f32()
		if self.on_moon then
			self.on_moon(moon)
		end
	end

	-- day_opacity came in 5.7 and the seed in 5.11, so an older server stops
	-- after the scale
	handlers[TOCLIENT.SET_STARS] = function(r)
		local stars = {}
		stars.visible = r:u8() ~= 0
		stars.count = r:u32()
		stars.color = read_color(r)
		stars.scale = r:f32()
		stars.day_opacity = 0
		if r:remaining() >= 4 then
			stars.day_opacity = r:f32()
		end
		if self.on_stars then
			self.on_stars(stars)
		end
	end

	-- A game's set_lighting(), flat by res/sky_model.lua's LIGHTING names.
	-- The exposure came in 5.8, the volumetric light and the tint in 5.9,
	-- the bloom after; what an older server leaves off keeps its default.
	handlers[TOCLIENT.SET_LIGHTING] = function(r)
		local l = {}
		local function f32(name)
			if r:remaining() >= 4 then
				l[name] = r:f32()
			end
		end
		f32("shadow_intensity")
		f32("saturation")
		for _, n in ipairs({"luminance_min", "luminance_max",
				"exposure_correction", "speed_dark_bright",
				"speed_bright_dark", "center_weight_power",
				"volumetric_strength"}) do
			f32(n)
		end
		if r:remaining() >= 4 then
			local c = read_color(r)
			l.tint_r, l.tint_g, l.tint_b = c[1], c[2], c[3]
		end
		f32("bloom_intensity")
		f32("bloom_strength_factor")
		f32("bloom_radius")
		if self.on_lighting then
			self.on_lighting(l)
		end
	end

	-- color_shadow came in 5.9
	handlers[TOCLIENT.CLOUD_PARAMS] = function(r)
		local clouds = {}
		clouds.density = r:f32()
		clouds.color_bright = read_color(r)
		clouds.color_ambient = read_color(r)
		clouds.height = r:f32()
		clouds.thickness = r:f32()
		clouds.speed = {r:f32(), r:f32()}
		if self.on_clouds then
			self.on_clouds(clouds)
		end
	end

	handlers[TOCLIENT.ACTIVE_OBJECT_REMOVE_ADD] = function(r)
		for _ = 1, r:u16() do
			local id = r:u16()
			if self.on_object_remove then
				self.on_object_remove(id)
			end
		end
		for _ = 1, r:u16() do
			local id = r:u16()
			local object_type = r:u8()
			local data = r:longstring()
			if self.on_object_add then
				self.on_object_add(id, object_type, data)
			end
		end
	end

	-- What the objects are doing, as a stream of per-object messages with no
	-- count in front of it: it runs to the end of the packet
	handlers[TOCLIENT.ACTIVE_OBJECT_MESSAGES] = function(r)
		while r:remaining() >= 4 do
			local id = r:u16()
			local data = r:string()
			if self.on_object_message then
				self.on_object_message(id, data)
			end
		end
	end

	-- Chat, which is both what players say and what the server answers a
	-- command with. The strings are wide ones; serialize.lua turns them into
	-- UTF-8.
	handlers[TOCLIENT.CHAT_MESSAGE] = function(r)
		local version = r:u8()
		if version ~= 1 then
			return
		end
		local message_type = r:u8()
		local sender = r:wstring()
		local text = r:wstring()
		if self.on_chat then
			self.on_chat(text, sender, message_type)
		end
	end

	handlers[TOCLIENT.HP] = function(r)
		self.hp = r:u16()
	end

	handlers[TOCLIENT.BREATH] = function(r)
		self.breath = r:u16()
	end

	handlers[TOCLIENT.NODEDEF] = function(r)
		local data = buildat.decompress(r:longstring(), defs_compression(self))
		got_nodedef = true
		if self.on_nodedef then
			self.on_nodedef(data)
		end
		maybe_send_client_ready()
	end

	-- ANNOUNCE_MEDIA at protocol 48 and up: a zstd frame of the file names,
	-- and then a raw 20-byte sha1 for each of them in the same order, in the
	-- rest of the packet.
	--
	-- The name table is Luanti's serializeString16Array, which is not a list
	-- of length-prefixed strings: it is a u32 count, then every length, then
	-- every string's bytes.
	handlers[TOCLIENT.ANNOUNCE_MEDIA] = function(r)
		local files = {}
		local count
		if self.protocol_version >= 48 then
			local nr = serialize.reader(
					buildat.decompress(r:longstring(), "zstd"))
			count = nr:u32()
			local sizes = {}
			for i = 1, count do
				sizes[i] = nr:u16()
			end
			for i = 1, count do
				files[i] = {name = nr:raw(sizes[i])}
			end
			for i = 1, count do
				files[i].sha1 = r:raw(20)
			end
		else
			-- Below 48 the names and the hashes are a plain list of pairs,
			-- and the hash is base64 rather than the 20 raw bytes
			count = r:u16()
			for i = 1, count do
				local name = r:string()
				files[i] = {name = name,
						sha1 = serialize.base64_decode(r:string())}
			end
		end
		-- Remote media servers, comma separated. Fetching over HTTP is not
		-- something this client does; the server sends what we ask it for.
		local remote = r:remaining() > 0 and r:string() or ""
		status("The server announced "..count.." media files")
		if self.on_announce_media then
			self.on_announce_media(files, remote)
		end
	end

	handlers[TOCLIENT.MEDIA] = function(r)
		local num_bunches = r:u16()
		local bunch_i = r:u16()
		local num_files = r:u32()
		local files = {}
		for i = 1, num_files do
			local name = r:string()
			local data = r:longstring()
			-- Below 48 the file goes over the wire as it is on disk
			if self.protocol_version >= 48 then
				data = buildat.decompress(data, "zstd")
			end
			files[i] = {name = name, data = data}
		end
		if self.on_media then
			self.on_media(files, bunch_i, num_bunches)
		end
	end

	handlers[TOCLIENT.MOVE_PLAYER] = function(r)
		local x, y, z = r:v3f()
		self.position = {x = x / BS, y = y / BS, z = z / BS}
		self.pitch = r:f32()
		self.yaw = r:f32()
		-- Nothing is told where we are until now, and PLAYERPOS would move us
		-- somewhere else if it went out before this
		if self.state ~= "ready" then
			self.state = "ready"
			status(string.format("Spawned at %.0f, %.0f, %.0f",
					self.position.x, self.position.y, self.position.z))
		end
	end

	-- The game's movement constants, which come before the player spawns.
	-- Twelve floats in the order LocalPlayer keeps them in; on the wire they
	-- are in nodes and Luanti scales them by BS on the way in.
	handlers[TOCLIENT.MOVEMENT] = function(r)
		local m = {}
		for _, name in ipairs(MOVEMENT_FIELDS) do
			m[name] = r:f32()
		end
		if self.on_movement then
			self.on_movement(m)
		end
	end

	-- One node changed. The position is a node position, not a block one, and
	-- at serialization version 24 and up a node on the wire is
	-- u16 param0 | u8 param1 | u8 param2.
	handlers[TOCLIENT.ADDNODE] = function(r)
		local x, y, z = r:v3s16()
		local param0 = r:u16()
		local param1 = r:u8()
		local param2 = r:u8()
		-- u8 keep_metadata follows; node metadata is not read here
		if self.on_node then
			self.on_node(x, y, z, param0, param1, param2)
		end
	end

	handlers[TOCLIENT.REMOVENODE] = function(r)
		local x, y, z = r:v3s16()
		if self.on_node then
			-- No light comes with a removal; the view works it out
			self.on_node(x, y, z, M.CONTENT_AIR, nil, 0)
		end
	end

	handlers[TOCLIENT.TIME_OF_DAY] = function(r)
		self.time_of_day = r:u16() % 24000
		self.time_speed = r:f32()
		self.time_of_day_f = self.time_of_day
	end

	handlers[TOCLIENT.BLOCKDATA] = function(r)
		local block = parse_blockdata(r:rest())
		self.blocks_received = self.blocks_received + 1
		-- The server throttles on unacknowledged blocks, so this has to go out
		-- whether anything makes use of the block or not
		gotblocks[#gotblocks + 1] = {block.x, block.y, block.z}
		if self.on_block then
			self.on_block(block)
		end
	end

	-- The metadata of voxels a server has changed: one zlib frame holding the
	-- same list a mapblock ends with, but with absolute positions.
	handlers[TOCLIENT.NODEMETA_CHANGED] = function(r)
		if not self.on_node_meta then
			return
		end
		local raw = buildat.decompress(r:longstring(), "zlib")
		local inner = serialize.reader(raw)
		self.on_node_meta(nodemeta.parse(inner, inventory, true))
	end

	handlers[TOCLIENT.ACCESS_DENIED] = function(r)
		local reason = r:u8()
		-- Only reason 10 carries a message of its own; for the rest the
		-- server sends the code and nothing else, and Luanti's own client
		-- is where the words live (accessDeniedStrings in
		-- clientpackethandler.cpp)
		local given = r:remaining() > 0 and r:string() or ""
		local named = DENY_REASON[reason]
		local message = given ~= "" and given or (named or "unknown reason")
		self.state = "denied"
		status("The server denied access: "..message..
				" (reason "..reason..")")
		-- One thing per line: the dialog this ends up in does not wrap. The
		-- hints are for the two a player can do something about; a code
		-- nothing here has a name for goes in as a number, because that is
		-- then the only thing to go on.
		local hint = nil
		if given ~= "" then
			hint = nil
		elseif reason == 0 then
			hint = "That name is registered with another password."
		elseif reason == 8 then
			hint = "Wait a minute and try again."
		elseif not named then
			hint = "(reason "..reason..")"
		end
		fail("The server denied access:\n"..message..
				(hint and "\n"..hint or ""), true)
	end

	local function handle_command(data, channel)
		self.commands_handled = self.commands_handled + 1
		local t0 = buildat.get_time_us()
		local r = serialize.reader(data)
		local command = r:u16()
		local handler = handlers[command]
		if handler then
			handler(r)
		else
			self.unhandled[command] = (self.unhandled[command] or 0) + 1
			if self.unhandled[command] == 1 then
				log:verbose("Not handled yet: "..
						(TOCLIENT_NAME[command] or "command")..
						string.format(" (0x%02x), %d bytes", command, #data))
			end
		end
		if self.on_command then
			self.on_command(command, data)
		end
		-- The worst command of the frame, by name, for the slow-frame line:
		-- one command costing a fifth of a second is a different problem
		-- from fifty costing their share, and which one it was is the whole
		-- question
		local spent = buildat.get_time_us() - t0
		if spent > (self.worst_command_us or 0) then
			self.worst_command_us = spent
			self.worst_command = (TOCLIENT_NAME[command] or
					string.format("0x%02x", command))..
					" ("..#data.." bytes)"
		end
	end

	conn.on_data = function(data, channel)
		local ok, err = pcall(handle_command, data, channel)
		if not ok then
			-- Which command it was, because the traceback only names the
			-- line inside the reader that ran out of packet
			local command = #data >= 2 and
					(data:byte(1) * 256 + data:byte(2)) or nil
			log:warning("Failed to handle "..
					(command and ((TOCLIENT_NAME[command] or "a command")..
					string.format(" (0x%02x)", command)) or "a command")..
					": "..tostring(err))
		end
	end

	conn.on_disconnect = function(reason)
		self.state = "disconnected"
		status("Disconnected: "..tostring(reason))
		fail("The connection to the server ended:\n"..tostring(reason))
	end

	-- Where we are and what we are doing, which is both what PLAYERPOS is
	-- and what INTERACT carries on the end of itself
	local function write_player_pos(w)
		local p = self.position
		-- Positions go as hundredths of a BS unit, so nodes * 1000
		w:v3s32(math.floor(p.x * BS * 100), math.floor(p.y * BS * 100),
				math.floor(p.z * BS * 100))
		local v = self.speed
		w:v3s32(math.floor(v.x * BS * 100), math.floor(v.y * BS * 100),
				math.floor(v.z * BS * 100))
		w:s32(math.floor(self.pitch * 100))
		w:s32(math.floor(self.yaw * 100))
		w:u32(self.keys)
		w:u8(math.floor(FOV * 80)) -- The server culls blocks outside this
		w:u8(WANTED_RANGE_BLOCKS)
		w:u8(0) -- Bits; the only one so far is an inverted camera
		-- The two f32 movement fields after this are optional and the server
		-- falls back to the keys when they are missing
		return w
	end

	local function send_playerpos()
		send_command(TOSERVER.PLAYERPOS, write_player_pos(
				serialize.writer()):data())
	end

	-- One packet holds a u8 count, so the acknowledgements go in batches; 32
	-- positions and the command still fit one datagram
	local GOTBLOCKS_PER_PACKET = 32

	local function send_gotblocks()
		while #gotblocks > 0 do
			local count = math.min(#gotblocks, GOTBLOCKS_PER_PACKET)
			local w = serialize.writer():u8(count)
			for i = 1, count do
				local p = table.remove(gotblocks, 1)
				w:v3s16(p[1], p[2], p[3])
			end
			send_command(TOSERVER.GOTBLOCKS, w:data())
		end
	end

	local playerpos_timer = PLAYERPOS_INTERVAL

	-- How long a frame may spend handling what the server sent. A burst of
	-- map blocks is a hundred packets at once and parsing one is not free, so
	-- what does not fit in this waits for the next frame; the counters say
	-- how many are waiting.
	local COMMAND_BUDGET_US = 4000
	-- Or this share of the last frame, measured on the clock, when that is
	-- more: a slow frame (the web's, a weak GPU's) left the commands 4 ms
	-- of every 100 or more, and a busy server's backlog grew without end
	-- ([LUANTI_NO_WORLD]: 2044 waiting on the web). Luanti's own client
	-- gives them up to 100 ms a frame. The frame grows by a third at most,
	-- and it cannot feed back further: the share of a longer frame is the
	-- same share. TimeStep is no measure: Urho3D caps it at 100 ms.
	local COMMAND_FRAME_SHARE = 0.25
	local last_update_us = nil

	-- How long the server may say nothing at all before this gives up on it.
	-- A live server acknowledges the position we send it several times a
	-- second, so silence this long means the other end is gone -- and
	-- without this, a client that connects to an address nothing answers
	-- sits there for good, resending its INIT.
	local SILENCE_LIMIT_S = 20
	-- How long a server that answers (its peer id, its pings) may leave the
	-- INIT without a HELLO. A Minetest 0.4 server (protocol 27 at most, still
	-- on Luanti's list) says nothing to an INIT asking for 37 or newer.
	local HELLO_LIMIT_S = 10

	function self:update(dtime)
		-- The day goes on between the times the server says what it is.
		-- Luanti's client does the same -- Environment::stepTimeOfDay -- and
		-- for the same reason: the server sends the time every few seconds,
		-- and a sky drawn from that alone steps across the sky rather than
		-- crossing it. The server's word resets this whenever it arrives.
		if self.time_of_day_f then
			self.time_of_day_f = (self.time_of_day_f +
					self.time_speed * 24000 / (24 * 3600) * dtime) % 24000
		end
		conn:update(dtime)
		-- Once something has gone wrong there is nothing left to be smooth
		-- for, and what is still in the queue is what says why
		local t0 = buildat.get_time_us()
		local handled_before = self.commands_handled
		self.worst_command_us = 0
		self.worst_command = nil
		local budget = COMMAND_BUDGET_US
		if last_update_us then
			budget = math.max(budget,
					(t0 - last_update_us) * COMMAND_FRAME_SHARE)
		end
		last_update_us = t0
		self.commands_waiting = conn:pump(
				self.failure and 1000000000 or budget)
		-- What this frame spent on what the server said, for the slow-frame
		-- line in init.lua: a spike is either this or the meshing
		self.last_command_us = buildat.get_time_us() - t0
		self.last_commands = self.commands_handled - handled_before
		-- Nothing from the other end for that long
		if not self.failure then
			local quiet = (buildat.get_time_us() -
					(conn.last_receive_us or started_us)) / 1000000
			if quiet >= SILENCE_LIMIT_S then
				status("The server has said nothing for "..
						math.floor(quiet).." seconds")
				fail("The server has not answered for "..
						math.floor(quiet).." seconds.\n"..
						(self.state == "init_sent" and
						"Is that the right address?" or
						"The connection seems to be gone."), true)
			end
		end
		if not self.failure and self.state == "init_sent" and
				conn.last_receive_us and
				buildat.get_time_us() - started_us >= HELLO_LIMIT_S * 1000000 then
			fail("The server answers but does not take the login.\nIt may be "..
					"older than Luanti 5.0: this client\nspeaks protocol "..
					CLIENT_PROTOCOL_VERSION_MIN.." to "..LATEST_PROTOCOL_VERSION..
					".", true)
		end
		if self.failure and not failure_told then
			failure_told = true
			if self.on_failed then
				self.on_failed(self.failure)
			end
		end
		if self.state ~= "ready" then
			return
		end
		playerpos_timer = playerpos_timer + dtime
		if playerpos_timer >= PLAYERPOS_INTERVAL then
			playerpos_timer = 0
			send_playerpos()
		end
		send_gotblocks()
	end

	-- Digging, placing and using, which all go as one command.
	--
	-- action is one of M.INTERACT_*, item is the hotbar slot the player is
	-- wielding, and pointed is nil or {under = {x, y, z}, above = {x, y, z}}
	-- for a node, or {object = id} for an active object. The server takes
	-- the wield index from this, and its anticheat wants a START_DIGGING at
	-- the same node before a DIGGING_COMPLETED, no sooner than the dig would
	-- have taken.
	function self:interact(action, item, pointed)
		local pt = serialize.writer()
		pt:u8(0) -- PointedThing version
		if pointed and pointed.under then
			pt:u8(1) -- POINTEDTHING_NODE
			pt:v3s16(pointed.under[1], pointed.under[2], pointed.under[3])
			pt:v3s16(pointed.above[1], pointed.above[2], pointed.above[3])
		elseif pointed and pointed.object then
			pt:u8(2) -- POINTEDTHING_OBJECT
			pt:u16(pointed.object)
		else
			pt:u8(0) -- POINTEDTHING_NOTHING
		end
		local w = serialize.writer()
		w:u8(action)
		w:u16(item or 0)
		w:longstring(pt:data())
		write_player_pos(w)
		send_command(TOSERVER.INTERACT, w:data())
	end

	-- What a form sends back when a button is pressed: the name the form was
	-- shown under, and the fields it holds. The button's own name is one of
	-- them, which is how the server knows which was pressed.
	function self:send_inventory_fields(formname, fields)
		local w = serialize.writer()
		w:string(formname)
		local count = 0
		for _, _ in pairs(fields) do
			count = count + 1
		end
		w:u16(count)
		for name, value in pairs(fields) do
			w:string(name)
			w:longstring(value)
		end
		send_command(TOSERVER.INVENTORY_FIELDS, w:data())
	end

	-- The same, for a form that came out of a node's own metadata rather
	-- than from the server showing one: the node's position goes in front,
	-- and the server runs the node's on_receive_fields instead of the
	-- player's.
	function self:send_nodemeta_fields(x, y, z, formname, fields)
		local w = serialize.writer()
		w:s16(x):s16(y):s16(z)
		w:string(formname)
		local count = 0
		for _, _ in pairs(fields) do
			count = count + 1
		end
		w:u16(count)
		for name, value in pairs(fields) do
			w:string(name)
			w:longstring(value)
		end
		send_command(TOSERVER.NODEMETA_FIELDS, w:data())
	end

	-- One line saying what the network and the map are doing, for a log from
	-- a session that went wrong. What a stall looks like: blocks stops
	-- climbing while unacked stays above zero on channel 2, which is where
	-- the map goes -- or the incoming queue on a channel never empties,
	-- which means a reliable packet went missing and everything behind it is
	-- waiting.
	function self:net_line()
		local parts = {}
		for channel, s in pairs(conn:stats()) do
			if s.unacked > 0 or s.incoming > 0 or s.splits > 0 then
				parts[#parts + 1] = string.format(
						"ch%d unacked %d, early %d, splits %d, in %d, out %d",
						channel, s.unacked, s.incoming, s.splits,
						s.next_in, s.next_out)
			end
		end
		return string.format("net: blocks %d, commands waiting %d%s%s",
				self.blocks_received, self.commands_waiting,
				#parts > 0 and " | " or "", table.concat(parts, " | "))
	end

	-- The blocks we no longer have, which is what makes the server send them
	-- again: it keeps track of what it has sent and skips a block it thinks
	-- we hold. What wants that is a node change, because the light around it
	-- is the server's arithmetic and not ours.
	function self:send_deleted_blocks(blocks)
		local w = serialize.writer()
		local count = math.min(#blocks, 255)
		w:u8(count)
		for i = 1, count do
			local b = blocks[i]
			w:s16(b[1]):s16(b[2]):s16(b[3])
		end
		send_command(TOSERVER.DELETEDBLOCKS, w:data())
	end

	-- Moving a stack from one inventory slot to another. The command is
	-- text, and the indices in it are zero-based; see IMoveAction::serialize
	-- in Luanti's inventorymanager.h.
	function self:send_inventory_move(count, from_inv, from_list, from_i,
			to_inv, to_list, to_i)
		send_command(TOSERVER.INVENTORY_ACTION,
				"Move "..count.." "..from_inv.." "..from_list.." "..
				(from_i - 1).." "..to_inv.." "..to_list.." "..(to_i - 1))
	end

	-- Crafting count times out of the craft grid of an inventory into its
	-- craftresult. See ICraftAction::serialize.
	function self:send_inventory_craft(count, inv)
		send_command(TOSERVER.INVENTORY_ACTION, "Craft "..count.." "..inv.." ")
	end

	-- Throwing a stack away, which the game turns into an item entity in
	-- front of the player. Same text shape as the move above; a count of
	-- zero is the whole stack. See IDropAction::serialize.
	function self:send_inventory_drop(count, from_inv, from_list, from_i)
		send_command(TOSERVER.INVENTORY_ACTION,
				"Drop "..count.." "..from_inv.." "..from_list.." "..
				(from_i - 1))
	end

	-- Says something, or runs a command when it starts with a slash. The
	-- server answers a command with a chat message of its own.
	-- What a landing cost, in hp, which Luanti's client works out itself and
	-- the server takes as said (Client::sendDamage)
	function self:send_damage(amount)
		send_command(TOSERVER.DAMAGE, serialize.writer():u16(amount):data())
	end

	function self:send_chat(text)
		if text == "" then
			return
		end
		send_command(TOSERVER.CHAT_MESSAGE,
				serialize.writer():wstring(text):data())
	end

	-- Asks the server for media files by name. The list is usually far too big
	-- for one datagram, which is what connection.lua's outgoing split is for.
	function self:request_media(names)
		if #names == 0 then
			return
		end
		local w = serialize.writer():u16(#names)
		for _, name in ipairs(names) do
			w:string(name)
		end
		send_command(TOSERVER.REQUEST_MEDIA, w:data())
		status("Asked for "..#names.." media files")
	end

	-- Where the client says it is, in nodes. The server sends the blocks
	-- around this and moves the player to it, so it is both the camera's
	-- position and the player's.
	function self:set_position(x, y, z, pitch, yaw)
		self.position = {x = x, y = y, z = z}
		self.pitch = pitch or self.pitch
		self.yaw = yaw or self.yaw
	end

	-- What the server is told we are doing, which is what its movement checks
	-- and its animations of us go by. speed is in nodes a second and keys is
	-- a mask of M.KEY_*.
	function self:set_motion(vx, vy, vz, keys)
		self.speed = {x = vx, y = vy, z = vz}
		self.keys = keys or 0
	end

	function self:send_client_ready()
		local w = serialize.writer()
		w:u8(VERSION.major):u8(VERSION.minor):u8(VERSION.patch):u8(0)
		w:string(VERSION.hash)
		w:u16(FORMSPEC_API_VERSION)
		send_command(TOSERVER.CLIENT_READY, w:data())
		status("Sent CLIENT_READY")
	end

	function self:disconnect()
		conn:disconnect()
	end

	send_init()
	return self
end

M.serialize = serialize
M.MAP_BLOCKSIZE = MAP_BLOCKSIZE
M.NODECOUNT = NODECOUNT
M.BS = BS
M.TOSERVER = TOSERVER
M.TOCLIENT = TOCLIENT
M.TOCLIENT_NAME = TOCLIENT_NAME

return M
-- vim: set noet ts=4 sw=4:
