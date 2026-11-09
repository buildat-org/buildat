-- A player's inventory: on each player entity ([KIT] stage 4d), Kit's own
-- store of their items, what c:count, c:add, c:take and c:list reach
-- unless a component replaces it for every player (a type with
-- inventory = true). Not placed.
-- [KIT_TOOLS_2] Item instances ([KIT_ITEM_WEAR_SHAPE]): an item can carry
-- its own data (kit/equipment's wear and loaded rounds, a component's
-- free fields): through the interface's extension argument, c:take(item,
-- n, ext) puts the data of the n taken in ext.instances; c:add(item, n,
-- {instances = {...}}) puts those first. So a worn sword given or moved
-- keeps its wear, and two wear apart. A replacing provider may do the
-- same or keep counts only.
-- [KIT_INVENTORY_PLAY] **Slots**: state `slots`, a list of {item, n,
-- inst} ({} an empty slot): one item a slot, n up to its stack size,
-- inst the data of its first ones (the rest new). Kit gives the rules as
-- its params (kit/game_rules': `slots` the size, 0 unlimited -- then a
-- slot an item and no stack limit, counts only --, `stack` the default
-- stack size, `stacks` {item = an item type's stack}, `full` "drop" or
-- "refuse"); `items` stays the counts ({item = n}, Kit's reading). The
-- extension argument also takes: slot (add: that slot first; take: from
-- it first -- the held slot), partial (add: what fits, ext.added the
-- count; false when none fits). Past the room an add is refused, or with
-- full "drop" what fits goes in and the rest into state `overflow`
-- ({item, n, inst}), which Kit drops as a pickup where the player is.
-- `died` (set by Kit) marks a death in this round (kit/arena's "keep only
-- the living's")
local MAX = 1000000

local function stack_of(c, item)
	local p = c.params or {}
	if (tonumber(p.slots) or 0) <= 0 then
		return MAX
	end
	local s = type(p.stacks) == "table" and tonumber(p.stacks[item]) or
			tonumber(p.stack) or 99
	return math.max(1, math.min(MAX, math.floor(s)))
end

-- The slots as a list to change (old states: the counts made slots)
local function slots_of(c)
	local out = {}
	for i, s in ipairs(type(c.state.slots) == "table" and c.state.slots or {}) do
		out[i] = type(s) == "table" and type(s.item) == "string" and
				(tonumber(s.n) or 0) > 0 and {item = s.item, n = s.n,
				inst = type(s.inst) == "table" and s.inst or nil} or {}
	end
	if #out == 0 and next(c.state.items or {}) then
		local names = {}
		for k in pairs(c.state.items) do names[#names + 1] = k end
		table.sort(names)
		local inst = type(c.state.inst) == "table" and c.state.inst or {}
		for _, k in ipairs(names) do
			out[#out + 1] = {item = k, n = c.state.items[k], inst = inst[k]}
		end
		c.state.inst = nil
	end
	return out
end

local function trim(l)
	while #l > 0 and (type(l[#l]) ~= "table" or next(l[#l]) == nil) do
		l[#l] = nil
	end
	return #l > 0 and l or nil
end

-- Back into the state: the slots (trailing empties dropped) and the counts
local function store(c, slots)
	local items = {}
	for _, s in ipairs(slots) do
		if s.item then
			items[s.item] = math.min(MAX, (items[s.item] or 0) + s.n)
		end
	end
	while #slots > 0 and not slots[#slots].item do
		slots[#slots] = nil
	end
	c.state.slots = slots
	c.state.items = items
end

local function count(slots, item)
	local n = 0
	for _, s in ipairs(slots) do
		if s.item == item then n = n + s.n end
	end
	return n
end

-- k into slot s, data from the front of `given` (consumed)
local function put(s, item, k, given)
	local new = {}
	for i = 1, k do
		local d = table.remove(given, 1)
		new[i] = type(d) == "table" and d or {}
	end
	if s.item then
		for i = #new + 1, k do new[i] = {} end
		for _, d in ipairs(s.inst or {}) do new[#new + 1] = d end
	end
	s.item, s.n, s.inst = item, (s.n or 0) + k, trim(new)
end

return {
	version = 1,
	about = {
		group = "Players",
		what = "A player's items; on each player, not placed.",
	},
	player = true,
	state = {
		items = {default = {}},
		slots = {default = {}},
		overflow = {default = {}},
		died = {default = false},
	},
	inventory_count = function(c, player, item)
		return count(slots_of(c), item)
	end,
	inventory_add = function(c, player, item, n, ext)
		local slots, st = slots_of(c), stack_of(c, item)
		local size = math.floor(tonumber(c.params.slots) or 0)
		-- Where it goes: the asked slot, the same item's, then empty ones
		local order, seen = {}, {}
		local function try(i)
			if not seen[i] then
				seen[i] = true
				order[#order + 1] = i
			end
		end
		-- (the asked slot may be past the last: a take emptied the ones
		-- after it, the held slot's item put back)
		local at = tonumber(ext.slot)
		if at and at >= 1 and at <= (size > 0 and size or 256) and
				at % 1 == 0 and (not slots[at] or not slots[at].item or
				slots[at].item == item) then
			try(at)
		end
		for i, s in ipairs(slots) do
			if s.item == item then try(i) end
		end
		for i, s in ipairs(slots) do
			if not s.item and (size <= 0 or i <= size) then try(i) end
		end
		for i = #slots + 1, size > 0 and size or #slots + 1 do
			try(i)
		end
		local room = 0
		for _, i in ipairs(order) do
			local s = slots[i]
			room = room + st - (s and s.item and s.n or 0)
			if room >= n then break end
		end
		local fits = math.min(n, room)
		if fits < n then
			if ext.partial then
				if fits == 0 then
					ext.added = 0
					return false
				end
			elseif c.params.full ~= "drop" then
				return false
			end
		end
		local given = {}
		for i, d in ipairs(type(ext.instances) == "table" and ext.instances or
				{}) do
			given[i] = d
		end
		local left, top = fits, #slots
		for _, i in ipairs(order) do
			if left <= 0 then break end
			slots[i] = slots[i] or {}
			local s = slots[i]
			local k = math.min(left, st - (s.item and s.n or 0))
			if k > 0 then
				put(s, item, k, given)
				left, top = left - k, math.max(top, i)
			end
		end
		for i = 1, top do slots[i] = slots[i] or {} end
		ext.added = fits
		if fits < n and not ext.partial then
			local o = type(c.state.overflow) == "table" and c.state.overflow or {}
			o[#o + 1] = {item = item, n = n - fits, inst = trim(given)}
			c.state.overflow = o
			c:log(item, n - fits, "do not fit: dropped")
		end
		store(c, slots)
		return true
	end,
	inventory_take = function(c, player, item, n, ext)
		local slots = slots_of(c)
		if count(slots, item) < n then
			return false
		end
		-- The asked slot first (the held one), then the first ones (an
		-- item's first instances, as before slots)
		local order = {}
		local at = tonumber(ext.slot)
		if at and slots[at] and slots[at].item == item then
			order[1] = at
		end
		for i = 1, #slots do
			if i ~= at and slots[i].item == item then
				order[#order + 1] = i
			end
		end
		local taken, left = {}, n
		for _, i in ipairs(order) do
			local s = slots[i]
			local k = math.min(left, s.n)
			local inst = s.inst or {}
			for _ = 1, k do
				taken[#taken + 1] = table.remove(inst, 1) or {}
			end
			s.n, s.inst = s.n - k, trim(inst)
			if s.n <= 0 then
				slots[i] = {}
			end
			left = left - k
			if left <= 0 then break end
		end
		store(c, slots)
		ext.instances = taken
		return true
	end,
	inventory_list = function(c, player)
		local t = {}
		for _, s in ipairs(slots_of(c)) do
			if s.item then
				t[s.item] = math.min(MAX, (t[s.item] or 0) + s.n)
			end
		end
		return t
	end,
}
