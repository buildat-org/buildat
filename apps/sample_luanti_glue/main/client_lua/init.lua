-- Buildat: apps/sample_luanti_glue/main/client_lua/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The module's client loop as it is, but for the HUD stage: a stub that
-- draws one label in place of the game's HUD, the hotbar and the
-- crosshair ([LUANTI_APP_GLUE]).
local magic = require("buildat/extension/urho3d")
local luanti = require("buildat/module/luanti")
local log = buildat.Logger("glue")

local keys = luanti.run_client({log = "glue"})
local label = magic.ui.root:CreateChild("Text")
label:SetFont(magic.cache:GetResource("Font", buildat.font_mono), 20)
label:SetPosition(20, 20)
keys.stage.hud = function(elements)
	label:SetText("glue HUD stub")
	log:info("hud stub: " .. #elements .. " elements")
end
log:info("glue client ready")
-- vim: set noet ts=4 sw=4:
