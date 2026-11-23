-- Brimstone Stunts' weapons ([KIT_TEMPLATE_CLEANUP]: the race's own
-- apart, one in a race's scene): a crate (kit/collectible's pickup, linked
-- to crate; its value the kind: gun, mines, boost, any: each in turn) arms
-- the car with a gun (`shots` ahead), mines (`mines`, dropped behind:
-- copies of the entity `mine`, their touched linked here by name) or a ram
-- boost (`boost_time` s, faster: the car's body var boost; a hit on a car
-- then hurts it: the car's ram, linked here). The fire key (its action
-- "fire", Left Ctrl by default; the left mouse button too: the action's
-- mouse = "left") uses it: a press counts up the car's body var fire, and
-- the car's step says fire with its heading (linked to fire here). Damage
-- is Kit's health (c:hurt): the race's on_died makes the wreck.
-- Only the cars the race has armed take crates, fire and are hit: arm by
-- the player (the race's GO, back on the road after a wreck), disarm by the
-- player (a wreck, the finish, a leave, a new run) and over (the race over:
-- everyone, the mines gone). What a car carries goes to `carrying` ("Gun
-- x6", "" none), for a kit/ui_text on the player's HUD. Bots take no crates.
local KINDS = {"gun", "mines", "boost"}

local function is_bot(by)
	return tostring(by):match("^bot:%d+$") ~= nil
end

local function player_of(c, by)
	for _, p in ipairs(c.players or {}) do
		if p.by == by then
			return p
		end
	end
end

local function names(c)
	return {gun = c.params.gun_text, mines = c.params.mines_text,
		boost = c.params.boost_text}
end

-- What by's car carries, to their HUD
local function tell(c, by, k)
	c:emit("carrying", k and k.weapon and names(c)[k.weapon] .. " x" .. k.ammo or "", by)
end

local function unboost(c, by, k)
	if k.boosted then
		k.boosted = nil
		c:body_var(by, "boost", nil)
	end
end

-- Disarmed: nothing carried, the boost off
local function disarm(c, by)
	local k = c.state.cars[by]
	if not k then
		return
	end
	c.state.cars[by] = nil
	unboost(c, by, k)
	if k.weapon then
		tell(c, by, nil)
	end
end

local function fire(c, by, k, p, heading)
	if not k.weapon or not p then
		return
	end
	local a = (tonumber(heading) or 0) * math.pi / 180
	local fx, fz = math.sin(a), math.cos(a)
	local at = p.pos
	if k.weapon == "gun" then
		-- The nearest armed car ahead within range, in a cone
		local best, bd
		for _, q in ipairs(c.players or {}) do
			if q.id ~= p.id and c.state.cars[q.by] and q.pos and not q.away then
				local dx, dz = q.pos[1] - at[1], q.pos[3] - at[3]
				local ahead = dx * fx + dz * fz
				local across = math.abs(dx * fz - dz * fx)
				if ahead > 0 and ahead < c.params.gun_range and
						across < 1.6 + ahead * 0.08 and (not bd or ahead < bd) then
					best, bd = q, ahead
				end
			end
		end
		c:effect{at = {at[1] + fx * 2.6, at[2] + 0.7, at[3] + fz * 2.6},
			dir = {fx, 0, fz}, spread = 3, count = 10, shape = "square",
			colors = {"#fff27a", "#ffb030"}, speed_min = 50, speed_max = 70,
			gravity = 0, ttl_min = 0.12, ttl_max = 0.3, size_min = 0.12,
			size_max = 0.2, light_time = 0.08, light_color = "#ffe080",
			light_range = 6}
		if best then
			c:hurt(best.id, {amount = c.params.gun_damage, type = "gun"})
			c:effect{at = {best.pos[1], best.pos[2] + 0.8, best.pos[3]},
				dir = {-fx, 0.5, -fz}, spread = 60, count = 14, shape = "square",
				colors = {"#ffffff", "#ffd040", "#ff6010"}, speed_min = 3,
				speed_max = 9, gravity = 10, ttl_min = 0.2, ttl_max = 0.5,
				size_min = 0.08, size_max = 0.16}
			c:log(c:name(by), "shoots", best.name)
		end
	elseif k.weapon == "mines" and c.params.mine ~= 0 then
		-- (its zone's 2x2 cells from its place: their middle on the car's line)
		local pos = {at[1] - fx * 3.4 - 0.5, at[2], at[3] - fz * 3.4 - 0.5}
		local id = c:spawn{entity = c.params.mine, pos = pos}
		if id then
			c.state.mines[tostring(id):match("%d+")] = pos
			c:send(id, "arm")
			c:log(c:name(by), "drops a mine", id, "at", math.floor(pos[1] * 10) / 10,
					math.floor(pos[3] * 10) / 10)
		end
	elseif k.weapon == "boost" then
		k.boosted = true
		c:body_var(by, "boost", true)
		c:after(c.params.boost_time, "unboost", {player = by})
		c:log(c:name(by), "boosts")
	end
	k.ammo = k.ammo - 1
	if k.ammo <= 0 then
		k.weapon, k.ammo = nil, nil
	end
	tell(c, by, k)
end

return {
	version = 1,
	no_position = true,
	reads_players = true,
	about = {
		group = "Game",
		what = "Brimstone Stunts' weapons: crates arm a racing car with a gun, mines or a ram boost, fired with the fire key.",
		inputs = {
			arm = "The player's car may take crates and be hit (the race's GO, or back on the road).",
			disarm = "The player's car carries nothing and is not hit (a wreck, the finish, a leave).",
			over = "The race is over: every car disarmed, the mines gone.",
			crate = "The player took a crate. Value: gun, mines, boost or any.",
			fire = "The player fires what their car carries. Value: the car's heading (degrees).",
			mine = "The player touched a mine. Value: the mine.",
			ram = "The player's boosted car rammed another. Value: the other's by.",
		},
		outputs = {
			carrying = "What the player's car carries, for their HUD. Value: \"Gun x6\", \"\" for nothing.",
		},
		params = {
			mine = "The mine dropped behind a car: copies of this entity.",
			shots = "Shots a gun crate gives.",
			mines = "Mines a mines crate gives.",
			boost_time = "Seconds a ram boost lasts.",
			gun_range = "How far ahead a gun shot reaches, metres.",
			gun_damage = "Health a gun shot takes.",
			mine_damage = "Health a mine takes.",
			ram_damage = "Health a boosted car's ram takes.",
			gun_text = "The gun's name on the HUD.",
			mines_text = "The mines' name on the HUD.",
			boost_text = "The ram boost's name on the HUD.",
		},
	},
	params = {
		mine = {type = "entity", default = 0},
		shots = {type = "number", default = 6, min = 1, max = 50},
		mines = {type = "number", default = 3, min = 1, max = 20},
		boost_time = {type = "number", default = 2.5, min = 0.1, max = 30},
		gun_range = {type = "number", default = 45, min = 1, max = 200},
		gun_damage = {type = "number", default = 3, min = 0, max = 100},
		mine_damage = {type = "number", default = 9, min = 0, max = 100},
		ram_damage = {type = "number", default = 6, min = 0, max = 100},
		gun_text = {cat = "hud", type = "string", default = "Gun"},
		mines_text = {cat = "hud", type = "string", default = "Mines"},
		boost_text = {cat = "hud", type = "string", default = "Ram boost"},
	},
	state = {
		-- {[by] = {weapon, ammo, boosted, rammed_at}}: the armed cars
		cars = {default = {}},
		-- {[by] = n}: the fire key's presses (the car's body var fire)
		presses = {default = {}},
		mines = {default = {}},
		dice = {default = 0},
	},
	actions = {{name = "fire", key = "Left Ctrl", label = "Fire", mouse = "left"}},
	inputs = {arm = "none", disarm = "none", over = "none", crate = "string",
		fire = "number", mine = "entity", ram = "string"},
	outputs = {carrying = "string"},
	on_away = function(c, by)
		disarm(c, by)
	end,
	on_timer = function(c, name, player)
		local by = tostring(player)
		local k = c.state.cars[by]
		if name == "unboost" and k then
			unboost(c, by, k)
		end
	end,
	-- The fire key: the car's body var fire counted up (its step fires
	-- along its heading)
	on_action = function(c, name, phase, value, by)
		if name ~= "fire" or phase ~= "pressed" or type(by) ~= "string" or
				not by:match("^player:%d+$") then
			return
		end
		local n = (c.state.presses[by] or 0) + 1
		c.state.presses[by] = n
		c:log(c:name(by), "presses fire")
		c:body_var(by, "fire", n)
	end,
	on_input = function(c, input, value, by)
		if input == "over" then
			for b in pairs(c.state.cars) do
				disarm(c, b)
			end
			for _, id in ipairs(c.made or {}) do
				c:remove(id)
			end
			c.state.mines = {}
			return
		end
		if type(by) ~= "string" or not (by:match("^player:%d+$") or is_bot(by)) then
			return
		end
		if input == "arm" then
			c.state.cars[by] = c.state.cars[by] or {}
			return
		elseif input == "disarm" then
			return disarm(c, by)
		end
		local k = c.state.cars[by]
		if not k then
			return
		end
		if input == "crate" then
			if is_bot(by) then
				return
			end
			local kind = names(c)[value] and value
			if not kind then
				c.state.dice = c.state.dice + 1
				kind = KINDS[c.state.dice % 3 + 1]
			end
			unboost(c, by, k)
			k.weapon = kind
			k.ammo = kind == "gun" and c.params.shots or kind == "mines" and c.params.mines or 1
			c:log(c:name(by), "picks up", kind)
			tell(c, by, k)
		elseif input == "fire" then
			fire(c, by, k, player_of(c, by), value)
		elseif input == "mine" then
			-- (an entity value: its id, or "entity:<id>")
			local key = tostring(value):match("%d+")
			local pos = key and c.state.mines[key]
			if not pos then
				c:log("a mine not of this race:", tostring(value))
				return
			end
			c.state.mines[key] = nil
			c:remove(tonumber(key))
			c:hurt(tonumber(by:match("%d+")), {amount = c.params.mine_damage, type = "mine"})
			c:effect{at = {pos[1] + 0.5, pos[2] + 0.4, pos[3] + 0.5}, count = 40, shape = "round",
				colors = {"#ffe14a", "#ff7a12", "#5a5050"}, speed_min = 3,
				speed_max = 10, gravity = -1, drag = 3, ttl_min = 0.3,
				ttl_max = 0.9, size_min = 0.25, size_max = 0.7, grow = 1,
				light_time = 0.4, light_color = "#ffa040", light_range = 12,
				light_brightness = 3}
			c:log(c:name(by), "hits a mine")
		elseif input == "ram" then
			local other = tostring(value)
			local q = player_of(c, other)
			if not (q and c.state.cars[other]) or (k.rammed_at or -9) > c.now - 0.5 then
				return
			end
			k.rammed_at = c.now
			c:hurt(q.id, {amount = c.params.ram_damage, type = "ram"})
			c:log(c:name(by), "rams", c:name(other))
		end
	end,
}
