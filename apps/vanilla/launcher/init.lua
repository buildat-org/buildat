-- Buildat: apps/vanilla/launcher/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The launcher game's tiles ([LAUNCH_GRID]): one per Luanti game
-- installed under user/shared/vanilla/games -- devtest, VoxeLibre,
-- whatever is there -- which is why the launch grid asks every time it is
-- shown; the import screens; and its settings -- the render mode a
-- session draws in, the view and the keys -- on its settings screen,
-- opened by the menu= param. A game tile starts the game's server through
-- vanilla with the game's name as the param, which the module reads as it
-- would a packet. The player sees the game's name, never the app's.
-- (Were builtin/luanti's until [LUANTI_APP_GLUE]: nothing there names
-- vanilla.)
local PRETTY = {mineclone2 = "VoxeLibre", minetest_game = "Minetest Game"}
return function(ctx)
	-- **A save is its game's** ([SAVE_ICON]): main.cpp keeps the game's
	-- id in the save (store main, key gameid), and a game's tile's id is
	-- its name, so a save shows its game's picture; one of a game not
	-- installed, or none, the grass block
	ctx.save_variant = {store = "main", key = "gameid",
		icon = "grass_block.png"}
	local out = {}
	for i, g in ipairs(buildat.list_installed_games("vanilla")) do
		local name = g.name
		if not name:find("%.old") then
			-- **A game says it is a game, with its own picture and its
			-- own size** ([LAUNCH_API]): without the category these
			-- twenty-two were "an action with no opinion" and a launch UI
			-- could not tell VoxeLibre from "Import a Luanti world", and without
			-- the icon they all drew grass_block.png, which the room's mark
			-- rule reads as no icon at all. g.icon is already resolved --
			-- the game's menu/icon.png, copied under the cache and
			-- namespaced by family and name -- so it is passed through
			-- rather than resolved again against this launcher's own
			-- directory.
			out[#out + 1] = {
				id = name, label = PRETTY[name] or name,
				icon = g.icon or "grass_block.png",
				resolved_icon = g.icon ~= nil,
				category = "game", significance = g.size,
				description = "Luanti game " .. name, order = 100 + i,
				run = function()
					-- The game's world selection: its saves, and a new one
					-- by name, on the launcher game's own save screen
					ctx.launch{app = "vanilla",
							params = {luanti_game = name, menu = "worlds"}}
				end,
			}
		end
	end
	-- And the two ways in: the launcher game's own import screens, whose
	-- lists are the server's, so the game opens them on a menu= param
	-- **The import screens are tools, not things to play** ([LAUNCH_API]'s
	-- four families: games, saves, servers, tools). A launch UI that
	-- shows the families apart -- the room puts tools on its terminal --
	-- had no way to tell these from a game without reading their names.
	out[#out + 1] = {id = "import_game", label = "Import a Luanti game",
		icon = "grass_block.png", order = 190, category = "tool",
		description = "Copy a game from a Luanti installation",
		run = function()
			ctx.launch{app = "vanilla", params = {menu = "import_game"}}
		end}
	out[#out + 1] = {id = "import_world", label = "Import a Luanti world",
		icon = "grass_block.png", order = 191, category = "tool",
		description = "Copy a world from a Luanti installation",
		run = function()
			ctx.launch{app = "vanilla", params = {menu = "import_world"}}
		end}
	out[#out + 1] = {id = "settings", label = "Luanti settings",
		icon = "grass_block.png", order = 192,
		category = "settings", section = "Luanti",
		description = "The render mode, the view, the keys",
		run = function()
			ctx.launch{app = "vanilla", params = {menu = "settings"}}
		end}
	-- ContentDB's games, fetched and installed by the server ([CONTENTDB])
	out[#out + 1] = {id = "contentdb", label = "ContentDB",
		icon = "grass_block.png", order = 193, category = "catalog",
		description = "Browse and install games from content.luanti.org",
		run = function()
			ctx.launch{app = "vanilla", params = {menu = "contentdb"}}
		end}
	-- On a save, not a tile ([SAVE_CONTEXT_MENU]): its worlds screen with
	-- that world selected
	out[#out + 1] = {id = "world_options", label = "World options...",
		for_save = true,
		run = function(save)
			ctx.launch{app = "vanilla", params = {menu = "worlds", world = save}}
		end}
	return out
end
