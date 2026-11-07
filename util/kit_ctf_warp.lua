-- SPDX-License-Identifier: Apache-2.0 OR MIT
-- The checks' workbench/warp (kit_ctf_check.sh, kit_templates_check.sh):
-- each action teleports who pressed it (`who` alone, "" anyone) to its
-- p<n>. Five
local acts, params = {}, {who = {type = "string", default = ""}}
for i, k in ipairs({"Y", "U", "I", "O", "P"}) do
	acts[i] = {name = "warp" .. i, key = k, label = "Warp " .. i}
	params["p" .. i] = {type = "position", default = {0, 1, 0}}
end
return {
	version = 1,
	actions = acts,
	params = params,
	on_action = function(c, name, phase, value, by)
		local p = c.params["p" .. name:sub(5)]
		if phase == "pressed" and p and not c.player_away and
				(c.params.who == "" or c.params.who == c:name(by)) then
			c:log(c:name(by), name, "to", p[1], p[2], p[3])
			c:teleport(p)
		end
	end,
}
