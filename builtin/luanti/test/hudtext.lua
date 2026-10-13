-- SPDX-License-Identifier: Apache-2.0 OR MIT
-- The colours inside a line of HUD text: core.colorize() writes Luanti's own
-- markup into it and each piece is drawn in the colour it asks for.
--
--   BUILDAT_LUANTI_GAME=devtest BUILDAT_LUANTI_SAVE=hudtext_check \
--   BUILDAT_LUANTI_LUA=builtin/luanti/test/hudtext.lua \
--   bin/buildat_server -m ../apps/vanilla -D ../user
--
-- Connect a client: four lines sit in the middle of the screen, the first
-- three coloured word by word and the last one plain, which is what says a
-- line with no markup in it still draws.
core.register_on_joinplayer(function(player)
	core.after(2, function()
		if not (player and player:is_player()) then
			return
		end
		local text =
				core.colorize("#ff4040", "red ") ..
				core.colorize("#40ff40", "green ") ..
				core.colorize("#8080ff", "blue") .. "\n" ..
				core.colorize("yellow", "a colour by name") .. "\n" ..
				core.colorize("#f0f", "three digits") ..
				" and then the line's own colour\n" ..
				"no markup at all"
		player:hud_add({
			hud_elem_type = "text",
			position = {x = 0.5, y = 0.4},
			alignment = {x = 0, y = 0},
			number = 0xC0C0C0,
			text = text,
		})
		core.log("action", "hud text check: four lines added")

		-- And what size.X does to it ([UI_PARITY]): Luanti multiplies its
		-- own default font size by it, so the second of these is three
		-- times the first. The same word in both, so a scan can measure
		-- them against each other.
		for i, scale in ipairs({1, 3}) do
			player:hud_add({
				hud_elem_type = "text",
				position = {x = 0.2, y = 0.2 + 0.2 * i},
				alignment = {x = 1, y = 0},
				number = 0xFFFFFF,
				size = {x = scale, y = 0},
				text = "sized" .. scale,
			})
		end

		-- Where align puts an element, which is the half of this that is
		-- easy to get backwards: all three are anchored on the middle of
		-- the screen, and align is what slides each one off it. Luanti's
		-- hud.cpp is `(align - 1) * size / 2`, so **-1 ends at the anchor,
		-- 0 straddles it and +1 starts at it** -- read down the column and
		-- the three arrows have to meet in one vertical line.
		local aligns = {
			{x = -1, text = "align -1 ends here >"},
			{x = 0, text = "< align 0 straddles >"},
			{x = 1, text = "< align +1 starts here"},
		}
		for i, a in ipairs(aligns) do
			player:hud_add({
				hud_elem_type = "text",
				position = {x = 0.5, y = 0.6 + i * 0.05},
				alignment = {x = a.x, y = 0},
				number = 0x80FFFF,
				text = a.text,
			})
		end
		core.log("action", "hud text check: three alignments added")
		-- In the client's log too, after the elements: what hudtext.sh's
		-- drive waits for
		core.chat_send_player(player:get_player_name(),
				"hud text check: the elements added")
	end)
end)
