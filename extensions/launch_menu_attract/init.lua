-- extensions/launch_menu_attract: [TWO_AUDIENCES]' third option, which
-- is **the two composed rather than a third thing** (user, 2026-09-23).
--
--   Build/bin/buildat -m launch_menu_attract
--
-- The room does its attract mode and the menu is stacked over it: the
-- menu takes every input and the room is the view out of the window.
-- That serves the person who wants the menu's convenience *and* likes
-- what the room looks like, which is probably more people than either
-- pure case.
--
-- **It is nearly free, and this file is the proof**: the attract mode
-- exists, the menu is UI, `uistack` is what a screen over a scene
-- already is, and composing is one verb. What each of the two offers is
-- the whole API between them -- the room a passive backdrop, the menu
-- its own boot.
local api = buildat.safe or buildat
local log = buildat.Logger("launch_menu_attract")
local M = {}
-- The scrim's image and texture, which Urho3D must not free under it
kept = nil

function M.boot(action)
	-- The room first, as the thing behind: it takes no input at all in
	-- this mode, so the order is only about which draws under which
	local ok, why = api.compose_launch_ui("launch_world", "backdrop")
	if not ok then
		-- **A composition with half of itself missing is not a
		-- launcher**: the menu alone is still a launcher, so it is what
		-- is left rather than an error screen
		log:warning("the room did not come up: " .. tostring(why))
	end
	-- **A scrim between the two**, and it belongs to the composition
	-- rather than to either half ([TWO_AUDIENCES]: do not degrade the
	-- menu, do not compromise the room). The room is bright and the
	-- menu is text over it; without this the grid is unreadable in
	-- front of a lit wall. Under the menu's own stack and over the
	-- scene, which is what a priority below zero is.
	local urho3d = require("buildat/core/urho3d")
	local magic = urho3d.Vector3 and urho3d or urho3d.safe
	local white = magic.Image:new()
	white:SetSize(2, 2, 3)
	for y = 0, 1 do
		for x = 0, 1 do
			white:SetPixel(x, y, magic.Color(1, 1, 1, 1))
		end
	end
	local tex = magic.Texture2D:new()
	tex:SetData(white)
	kept = {white, tex}
	local scrim = magic.ui.root:CreateChild("BorderImage")
	scrim.texture = tex
	scrim.imageRect = magic.IntRect(0, 0, 2, 2)
	scrim.color = magic.Color(0.02, 0.03, 0.05, 0.72)
	scrim.priority = -1
	scrim:SetPosition(0, 0)
	scrim:SetFixedSize(magic.ui.root.width, magic.ui.root.height)

	local ok2, why2 = api.compose_launch_ui("launch_menu", action)
	if not ok2 then
		log:error("the menu did not come up: " .. tostring(why2))
		return
	end
	log:info("the menu, over the room" ..
			(ok and "" or " (without the room)"))
end

return M
-- vim: set noet ts=4 sw=4:
