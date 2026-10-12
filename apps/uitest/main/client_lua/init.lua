-- Buildat: uitest/client_lua/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("uitest")
local magic = require("buildat/extension/urho3d")
local uistack = require("buildat/extension/uistack")
log:info("uitest/init.lua loaded")

local ui_stack = uistack.main

-- A texture the program builds itself, with no texture file anywhere: an
-- Image filled pixel by pixel and handed to Texture2D:SetData, which is
-- what a program whose whole look is procedural needs ([LAUNCH_WORLD]).
-- Asserted rather than looked at, so a whitelist entry that goes missing
-- fails a run instead of drawing nothing (see [WHITELIST_POLICY]).
-- Held at file scope: a Texture2D made in Lua is owned by Lua, and a local
-- that goes out of scope takes the texture with it even though an element
-- is drawing with it (the same lifetime trap as a cached Material)
local kept = {}
local function check_procedural_texture(parent)
	-- 64, so the element Urho3D sizes to the texture is big enough to read
	-- in a shot; an image element takes its texture's size and the size a
	-- script asks for is thrown away
	local SIZE = 64
	local image = magic.Image:new()
	assert(image:SetSize(SIZE, SIZE, 3), "Image:SetSize")
	for y = 0, SIZE - 1 do
		for x = 0, SIZE - 1 do
			image:SetPixel(x, y, magic.Color(x / (SIZE - 1),
					y / (SIZE - 1), 0.25, 1))
		end
	end
	local texture = magic.Texture2D:new()
	kept.image, kept.texture = image, texture
	assert(texture:SetData(image), "Texture2D:SetData")
	assert(texture.width == SIZE and texture.height == SIZE,
			"the texture is the image's size")
	-- The UI root rather than the pushed screen: that root lays its
	-- children out and a swatch in it comes out 0 wide
	local element = magic.ui.root:CreateChild("BorderImage")
	element:SetName("procedural_swatch")
	element.position = magic.IntVector2(8, 8)
	-- Without a source rect an Urho3D image element tiles its texture
	-- rather than drawing it once; and the swatch sits over whatever the
	-- rest of the UI has put on the root
	element.imageRect = magic.IntRect(0, 0, SIZE, SIZE)
	element.priority = 100
	element.texture = texture
	element.size = magic.IntVector2(SIZE, SIZE)
	assert(element.size.x == SIZE and element.size.y == SIZE,
			"the swatch is the size it was given")
	assert(element.texture ~= nil, "BorderImage.texture reads back")
	-- Material:SetTexture is the other half of the bill: the same texture
	-- on a material, which is how it reaches a mesh rather than the UI
	local material = magic.Material:new()
	kept.material = material
	material:SetTexture(magic.TU_DIFFUSE, texture)
	log:info("procedural texture ok: " .. SIZE .. "x" .. SIZE ..
			" image into a Texture2D, on a BorderImage and a Material")
end

-- A sound the program makes itself, with no audio file anywhere: samples
-- written into a VectorBuffer, handed to a BufferedSoundStream and played
-- by a SoundSource ([LAUNCH_WORLD], whose audio is synthesised and has no
-- assets). Asserted rather than listened to, since a scripted run has no
-- ears; what it proves is that the block reaches the stream.
local function check_procedural_sound()
	local RATE = 22050
	local SAMPLES = math.floor(RATE / 4)  -- a quarter of a second
	local stream = magic.BufferedSoundStream:new()
	stream:SetFormat(RATE, true, false)  -- 16-bit, mono
	-- An underrun is a gap in the sound, not the end of it: the stream
	-- stays open and the script tops it up
	stream.stopAtEnd = false
	local buffer = magic.VectorBuffer:new()
	for i = 0, SAMPLES - 1 do
		local v = math.sin(i * 2 * math.pi * 440 / RATE) * 12000
		buffer:WriteShort(math.floor(v))
	end
	assert(buffer:GetSize() == SAMPLES * 2, "two bytes a sample, got " ..
			buffer:GetSize() .. " for " .. SAMPLES)
	stream:AddData(buffer)
	assert(stream.bufferNumBytes == buffer:GetSize(),
			"the stream took the block")
	-- A SoundSource is a Component, so it wants a node; uitest has no
	-- scene of its own and one node in one scene is the whole of it
	kept.sound_scene = magic.Scene()
	local node = kept.sound_scene:CreateChild("sound")
	local source = node:CreateComponent("SoundSource")
	source.gain = 0.0  -- a scripted run should not make a noise
	source:Play(stream)
	kept.stream, kept.source = stream, source
	log:info(string.format(
			"procedural sound ok: %d bytes, %.2f s buffered, playing %s",
			stream.bufferNumBytes, stream.bufferLength,
			tostring(source.playing)))
end

function show_stuff()
	local root = ui_stack:push({desc="uitest root"})
	root.defaultStyle = magic.cache:GetResource("XMLFile", "ui_utils/res/style.xml")

	local window = root:CreateChild("Window")
	window:SetStyleAuto()
	window:SetName("window")
	window:SetLayout(magic.LM_VERTICAL, 10, magic.IntRect(10, 10, 10, 10))
	window:SetAlignment(magic.HA_LEFT, magic.VA_CENTER)

	local message_text = window:CreateChild("Text")
	message_text:SetName("message_text")
	message_text:SetStyleAuto()
	message_text.text = "Stuff"
	message_text:SetTextAlignment(magic.HA_CENTER)

	check_procedural_texture(root)
end

show_stuff()
check_procedural_sound()


function handle_keydown(event_type, event_data)
	local key = event_data:GetInt("Key")
	if key == magic.KEY_ESCAPE then
		log:info("KEY_ESCAPE pressed")
		buildat.leave()
	end
end
magic.SubscribeToEvent("KeyDown", "handle_keydown")


-- [CONSENT_PER_SERVER]: a script asks for an address, as this server.
-- util/consent_check.sh reads whether the client asked the user or took
-- the answer the user gave this server. Port 9 has nobody on it.
require("buildat/extension/network").tcp_connect("localhost", 9,
		function(socket, err)
	log:info("uitest: tcp_connect: "..tostring(err or "connected"))
end, {description = "uitest's consent probe"})
-- vim: set noet ts=4 sw=4:
