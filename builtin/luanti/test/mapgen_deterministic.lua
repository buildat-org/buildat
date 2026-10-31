-- [MCL_GEN_NONDETERMINISTIC]: a fixture for mapgen_deterministic.sh. A box
-- of sections is forceloaded, which the streamer generates with no player
-- around, and "det: the box is in" is logged once a node of each reads as
-- something other than ignore. Two sections along x and z, two high.
local across = 2
local points = {}
core.after(1, function()
	local size = tonumber(__luanti_section_size) or 64
	for x = 0, across - 1 do
	for y = -1, 0 do
	for z = 0, across - 1 do
		local p = {x = x * size, y = y * size, z = z * size}
		core.forceload_block(p, true)
		points[#points + 1] = p
	end
	end
	end
	core.log("action", "det: asked for " .. #points .. " sections")
	local function poll()
		for _, p in ipairs(points) do
			if core.get_node(p).name == "ignore" then
				core.after(0.2, poll)
				return
			end
		end
		core.log("action", "det: the box is in")
	end
	poll()
end)
