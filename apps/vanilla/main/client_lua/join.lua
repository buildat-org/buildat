-- Buildat: apps/vanilla/main/client_lua/join.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- A public server's first script ([VANILLA_PUBLIC] 2): the join, through
-- builtin/accounts. What comes after is the server's to send: the world,
-- the world menu for an admin while there is none, or else a wait until an
-- admin has chosen one.
local cereal = require("buildat/extension/cereal")
local log = buildat.Logger("vanilla")

local _, err, accounts = buildat.run_script_file("accounts/accounts.lua")
if type(accounts) ~= "table" then
	error("vanilla: could not load accounts.lua: " .. tostring(err))
end

local wait = nil
local function close_wait()
	if wait then
		wait:Remove()
		wait = nil
	end
end


-- [VANILLA_STOP] No world running (an admin stopped it, or has not
-- chosen one): the pause menu's pages that need no world, held until the
-- world comes -- no Continue, and Escape does not close it. The chat is
-- vanilla's own then (main:chat_line), the game's being down.
local wait_text = ""
local function draw_wait()
	close_wait()
	accounts.close_page()
	local w = accounts.page_window(420)
	wait = w
	accounts.page_text(w, wait_text)
	local function back()
		draw_wait()
	end
	accounts.page_button(w, "Chat...", function()
		close_wait()
		accounts.chat_page(back)
	end)
	if buildat.show_game_settings then
		accounts.page_button(w, "Settings...", function()
			close_wait()
			buildat.show_game_settings{on_close = back}
		end)
	end
	accounts.page_button(w, "My account...", function()
		close_wait()
		accounts.account_page(back)
	end)
	if buildat.get_env("BUILDAT_PAGE_HTTPS") == nil then
		accounts.page_button(w, "Leave the game", function() buildat.leave() end)
	else
		accounts.page_button(w, "Log out", accounts.logout)
	end
	log:info("join: held: " .. wait_text)
end
accounts.chat_send = function(text)
	buildat.send_packet("main:chat",
			cereal.binary_output({text}, {"array", "string"}))
end
buildat.sub_packet("main:chat_line", function(data)
	local line = cereal.binary_input(data, {"array", "string"})[1] or ""
	log:info("join: chat: " .. line)
	accounts.chat_add(line)
end)

-- Escape on a page of it (the chat, My account) is that page's Back, as
-- the pause menu's hold makes it in the world; on the page itself, nothing
local magic = require("buildat/extension/urho3d")
magic.SubscribeToEvent("KeyDown", function(_, d)
	if wait_text ~= "" and not wait and
			d:GetInt("Key") == magic.KEY_ESCAPE then
		accounts.back()
	end
end)

buildat.sub_packet("main:join_wait", function(data)
	wait_text = cereal.binary_input(data, {"array", "string"})[1] or ""
	draw_wait()
end)

-- The world is here; the world menu, when it loads, takes this over
buildat.sub_packet("main:menu_done", function()
	wait_text = ""
	close_wait()
	accounts.close_page()
end)

-- The title is the Luanti game the server runs, which the server says
-- right after starting this script
buildat.sub_packet("main:join_title", function(data)
	local title = cereal.binary_input(data, {"array", "string"})[1] or ""
	-- The pause menu has "My account..."; no corner button ([ACCOUNT_BUTTON])
	accounts.no_account_button()
	accounts.start({title = title ~= "" and title or "Luanti"})
end)
-- vim: set noet ts=4 sw=4:
