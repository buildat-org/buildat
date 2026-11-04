-- A player's equipment ([KIT_TOOLS_1], stage 7c): on each player entity,
-- the hands slot -- the item they hold, one of their items, picked on
-- their client's hotbar (Kit sets it; it empties when the item is gone).
-- [KIT_INVENTORY_PLAY] `slot` the inventory's slot the hands hold (Kit
-- sets it with hands; 0 none): its instance is the held one, so two
-- swords in two slots are held and worn apart.
-- [KIT_TOOLS_2] The held item is an instance (kit/inventory's: the first
-- of that item), its own wear (uses left) and loaded rounds kept on it:
-- two swords wear apart, a worn one given keeps its wear. Kit runs
-- on_tool after each use (a dig, a hit, a shot) and as the hands take an
-- item: a drop added, the wear taken (at 0 the instance breaks: "broke"),
-- a shot's round taken from the magazine (or an ammo item where it has
-- none; none left: refused); state "held" is the held instance's data
-- for the client. on_reload loads rounds (a whole magazine or one) from
-- the ammo items, if it takes any. Stage 8's other slots go beside the
-- hands. Not placed
-- simplified: an item type's repair item is kept on its sheet, and
-- nothing mends with it yet (a station's job)
local function take(c, item)
	local ext = {slot = c.state.slot}
	if not c:take(item, 1, ext) then
		return nil
	end
	return type(ext.instances) == "table" and ext.instances[1] or {}
end

local function put(c, item, inst)
	c:add(item, 1, {instances = {inst}, slot = c.state.slot})
	c.state.held = inst
end

return {
	version = 1,
	player = true,
	equipment = true,
	state = {
		hands = {default = "", shared = true},
		slot = {default = 0, shared = true},
		held = {default = {}, shared = true},
	},
	outputs = {broke = "any"},
	on_tool = function(c, item, cost, uses, drop, shot)
		if drop then
			c:add(drop, 1)
			c:log("drop", drop)
		end
		if item == "" then
			return
		end
		local inst = take(c, item)
		if not inst then
			return false, "no " .. item
		end
		if shot then
			local mag = shot.magazine or 0
			if mag > 0 then
				local loaded = inst.loaded or mag
				if loaded < shot.rounds then
					put(c, item, inst)
					return false, item .. " is empty: reload"
				end
				inst.loaded = loaded - shot.rounds
				c:log(item, "rounds left", inst.loaded)
			elseif shot.ammo ~= "" and not c:take(shot.ammo, shot.rounds) then
				put(c, item, inst)
				return false, "no " .. shot.ammo
			end
		end
		if cost > 0 and uses > 0 then
			local left = (inst.wear or uses) - cost
			if left <= 0 then
				c.state.held = {}
				c:log(item, "breaks")
				c:emit("broke", item)
				return
			end
			inst.wear = left
			c:log(item, "uses left", left)
		end
		put(c, item, inst)
	end,
	-- A reload's round in: true while one at a time has more to load
	on_reload = function(c, item, magazine, ammo, one)
		local inst = take(c, item)
		if not inst then
			return false
		end
		local loaded = inst.loaded or magazine
		local n = one and math.min(1, magazine - loaded) or magazine - loaded
		if ammo ~= "" and n > 0 then
			n = math.min(n, c:count(ammo))
			if n > 0 then
				c:take(ammo, n)
			end
		end
		inst.loaded = loaded + n
		put(c, item, inst)
		c:log(item, "loaded", inst.loaded, "of", magazine)
		return one and inst.loaded < magazine and (ammo == "" or
				c:count(ammo) > 0)
	end,
}
