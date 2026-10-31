-- [KIT_VOXEL_STATES] A box of cells (its own and `size` on, 16 a side at
-- most) in one of two recorded states: A (off) and B (on), each a pattern
-- of the box's voxels (parameters a and b, which the inspector's Capture,
-- Show and Fill buttons edit). "on" and "off" write that state's pattern
-- into the box, the cells that differ; an empty state writes nothing.
-- Its writes are game changes: End puts the start back. The round starts
-- in its start state (start_on: B), that pattern written. Unseen in play;
-- the editor draws its box

-- A pattern ("<sx> <sy> <sz>;<names>;<runs>", builtin/kit/api.h) as its
-- size and its cells' names in box order; nil for none
local function decode(text)
	local sx, sy, sz, names, runs = tostring(text):match(
			"^(%d+) (%d+) (%d+);([^;]*);(.*)$")
	if not sx then
		return nil
	end
	local pal, cells = {}, {}
	for n in names:gmatch("%S+") do
		pal[#pal + 1] = n
	end
	for r in runs:gmatch("%S+") do
		local i, n = r:match("^(%d+)%*(%d+)$")
		i, n = tonumber(i or r), tonumber(n or 1)
		local name = i and pal[i + 1]
		if not name or not n then
			return nil
		end
		for _ = 1, n do
			cells[#cells + 1] = name
		end
	end
	return {tonumber(sx), tonumber(sy), tonumber(sz)}, cells
end

local function write(c, on, by)
	local which = on and "B" or "A"
	local text = on and c.params.b or c.params.a
	if text == "" then
		c:log(which, "is empty: nothing written, by", c:name(by))
		return
	end
	local size, cells = decode(text)
	local b = c.box
	if not size or size[1] ~= b[1] or size[2] ~= b[2] or size[3] ~= b[3] then
		c:log(which, "is of another box than its", b[1] .. "x" .. b[2] .. "x" ..
				b[3], "(capture it again): nothing written")
		return
	end
	local now, writes = c:voxels(), {}
	local sx, sz = b[1], b[3]
	for i, v in ipairs(cells) do
		if now[i] ~= v then
			local j = i - 1
			writes[#writes + 1] = {j % sx, math.floor(j / (sx * sz)),
					math.floor(j / sx) % sz, v}
		end
	end
	if #writes > 0 then
		c:set_voxels(writes)
	end
	c:log(which .. ":", #writes, "cells written by", c:name(by))
end

local function set(c, on, by)
	if on == c.state.on then
		return
	end
	c.state.on = on
	write(c, on, by)
	c:emit("changed", on)
end

return {
	version = 1,
	voxel_box = "size",
	reads_voxels = true,
	params = {
		size = {type = "position", default = {3, 3, 3}},
		start_on = {type = "bool", default = false},
		a = {type = "voxels", default = ""},
		b = {type = "voxels", default = ""},
	},
	state = {on = {default = false, shared = true}},
	gizmo = {shape = "box", size = 0.2, color = "#60c060"},
	inputs = {on = "none", off = "none", toggle = "none"},
	outputs = {changed = "bool"},
	on_start = function(c)
		c.state.on = c.params.start_on
		write(c, c.state.on, "its start")
	end,
	on_input = function(c, input, value, by)
		set(c, input == "on" or (input == "toggle" and not c.state.on), by)
	end,
}
