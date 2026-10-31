-- [KIT_VOXEL_STATES] A find-and-replace in a box of cells (its own and
-- `size` on, 16 a side at most): "on" makes every `find` cell in it
-- `replace` and remembers those cells; "off" turns back to `find` exactly
-- those that still hold `replace` (a cell that was `replace` before On
-- stays, one dug in between stays dug). Either may be air. Its writes are
-- game changes: End puts the start back. On at the start with start_on.
-- Unseen in play; the editor draws its box

-- A box index (from 1, x fastest, then z, then y) as its cell
local function xyz(c, i)
	local sx, sz = c.box[1], c.box[3]
	local j = i - 1
	return j % sx, math.floor(j / (sx * sz)), math.floor(j / sx) % sz
end

local function set(c, on, by)
	if on == c.state.on then
		return
	end
	local cells, writes = c:voxels(), {}
	local find, replace = c.params.find, c.params.replace
	if on then
		local changed = {}
		if find ~= "" and replace ~= "" and find ~= replace then
			for i, v in ipairs(cells) do
				if v == find then
					local x, y, z = xyz(c, i)
					writes[#writes + 1] = {x, y, z, replace}
					changed[#changed + 1] = i
				end
			end
		end
		c.state.changed = table.concat(changed, " ")
	else
		for s in string.gmatch(c.state.changed or "", "%d+") do
			local i = tonumber(s)
			if cells[i] == replace then
				local x, y, z = xyz(c, i)
				writes[#writes + 1] = {x, y, z, find}
			end
		end
		c.state.changed = ""
	end
	if #writes > 0 then
		c:set_voxels(writes)
	end
	c.state.on = on
	c:log(on and "on:" or "off:", #writes, "cells",
			on and (find .. " to " .. replace) or (replace .. " to " .. find),
			"by", c:name(by))
	c:emit("changed", on)
end

return {
	version = 1,
	voxel_box = "size",
	reads_voxels = true,
	params = {
		size = {type = "position", default = {3, 3, 3}},
		find = {type = "voxel", default = "kit/stone"},
		replace = {type = "voxel", default = "air"},
		start_on = {type = "bool", default = false},
	},
	state = {
		on = {default = false, shared = true},
		-- The cells On changed (box indices), the round's own
		changed = {default = ""},
	},
	gizmo = {shape = "box", size = 0.2, color = "#a060e0"},
	inputs = {on = "none", off = "none", toggle = "none"},
	outputs = {changed = "bool"},
	on_start = function(c)
		if c.params.start_on then
			set(c, true, "its start")
		end
	end,
	on_input = function(c, input, value, by)
		set(c, input == "on" or (input == "toggle" and not c.state.on), by)
	end,
}
