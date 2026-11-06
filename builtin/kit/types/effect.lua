-- An effect ([KIT_PARTICLES], [KIT_FEEDBACK_EFFECTS]): what the clients
-- show at a moment, and nothing else (no play reads it). A burst of `count`
-- particles (0: none): `shape` square, round, ring, or voxel (the event's
-- voxels' materials' textures), `color` and `color2` shared between them
-- ("" none); leaving along `axis` in a cone of `spread` degrees either side
-- (180: every way; simplified: a square cone, its corners a little wider),
-- from a box `box` m a side at the place plus `offset`, at speed_min to
-- speed_max m/s, falling at `gravity` m/s/s (negative: rising), slowed by
-- `drag`, living ttl_min to ttl_max s, fading over the last `fade` of it,
-- size_min to size_max m a side, growing by `grow` times itself a second,
-- turning `spin` degrees a second; `land`: stopping on the voxels' ground,
-- within 3 cells of the place (the place's column's ceiling: then it falls
-- through). A light for light_time s, never with a shadow: light_color,
-- light_range, light_brightness.
-- When: `on`. "signal": the inputs below. Kit's world events (each at its
-- place, as api.h's on_event says): "dig", "place" (the voxel's material,
-- for shape voxel), "hit" (at the target's body, a health's hit), "blast"
-- (the blown voxels' commonest materials), "respawn", "pickup".
-- With a hit: `along_hit` the axis is the way it sprays (away from a blast,
-- towards a hitter); `scale_by_damage` the count times the share of the
-- target's health it took (1 at least); and on a player, flash_time s of
-- their body in flash_color for all to see, and arc_time s of an arc in
-- arc_color on their own screen's edge towards where it came from.
-- Inputs: burst (one, its value by `where`), on (a burst now and then every
-- `every` s, `repeats` of them, 0 for ever, until off), off, color (a team's
-- name or "#rrggbb" for `color` from now on, "" its own).
-- Where a burst is: `where` "self": `at_entity` (the clients following its
-- look) or its own place; "value": a position, an entity, a player's name, or
-- a team's name (each of its live players, 32 at most); "who": the player who
-- set it off. `team_color`: `color` is the team a name in the value names, or
-- that player's.
-- Output: fired (where it was, a position; kit/controls' shake takes it).
-- Other types may call c:effect themselves (api.h)
local FIELDS = {"shape", "offset", "spread", "speed_min", "speed_max",
	"gravity", "drag", "ttl_min", "ttl_max", "size_min", "size_max", "grow",
	"fade", "box", "spin", "land", "light_color", "light_range",
	"light_brightness", "light_time"}

local function team_named(c, name)
	for _, t in ipairs(c.teams or {}) do
		if t.params.name == name then
			return t
		end
	end
end

local function team_of(c, id)
	for _, t in ipairs(c.teams or {}) do
		for _, m in ipairs(t.state.members or {}) do
			if m == id then
				return t
			end
		end
	end
end

local function player_named(c, name)
	for _, p in ipairs(c.players or {}) do
		if p.name == name then
			return p
		end
	end
end

-- o: at, entity, dir, count, color, voxels, player, from
local function burst(c, o)
	local p = c.params
	local d = {}
	for _, k in ipairs(FIELDS) do
		d[k] = p[k]
	end
	d.at, d.entity, d.voxels = o.at, o.entity, o.voxels
	d.dir = o.dir or p.axis
	d.count = o.count or p.count
	local own = c.state.color ~= "" and c.state.color or p.color
	d.colors = {o.color or own}
	if p.color2 ~= "" then
		d.colors[2] = p.color2
	end
	if o.player then
		d.player = o.player
		d.flash_color, d.flash_time = p.flash_color, p.flash_time
		if o.from then
			d.arc_color, d.arc_time, d.arc_from = p.arc_color, p.arc_time, o.from
		end
	end
	c:effect(d)
end

local function color_of(t)
	return t and t.params.color or nil
end

-- A burst by a signal's value
local function fire(c, value)
	local p = c.params
	local kind = type(value)
	local team = kind == "string" and team_named(c, value)
	local pl = kind == "string" and not team and player_named(c, value)
	local color
	if p.team_color then
		color = color_of(team or (pl and team_of(c, pl.id)) or
				(c.player and team_of(c, c.player)))
	end
	if p.where == "value" and team then
		local left = 32
		for _, id in ipairs(team.state.members or {}) do
			for _, q in ipairs(c.players or {}) do
				if q.id == id and q.pos and q.alive and not q.away and left > 0 then
					left = left - 1
					burst(c, {at = q.pos, color = color})
					c:emit("fired", q.pos)
				end
			end
		end
		return
	end
	local o = {color = color}
	if p.where == "value" and kind == "table" then
		o.at = value
	elseif p.where == "value" and kind == "number" then
		o.entity = value
	elseif p.where == "value" and pl then
		o.at = pl.pos
	elseif p.where == "who" and c.player then
		for _, q in ipairs(c.players or {}) do
			if q.id == c.player then
				o.at = q.pos
			end
		end
	elseif p.at_entity ~= 0 then
		o.entity = p.at_entity
	end
	burst(c, o)
	c:emit("fired", o.at or c.pos)
end

return {
	version = 1,
	players = true,
	teams = true,
	events = "on",
	gizmo = {shape = "sphere", size = 0.15, color = "#ffa040"},
	params = {
		on = {type = "string", default = "signal", choices = {"signal", "dig",
			"place", "hit", "blast", "respawn", "pickup"}},
		where = {type = "string", default = "self",
			choices = {"self", "value", "who"}},
		at_entity = {type = "entity", default = 0},
		every = {type = "number", default = 0.5, min = 0.05, max = 3600},
		repeats = {type = "number", default = 0, min = 0, max = 100000},
		team_color = {type = "bool", default = false},
		along_hit = {type = "bool", default = false},
		scale_by_damage = {type = "bool", default = false},
		count = {cat = "look", type = "number", default = 12, min = 0, max = 256},
		shape = {cat = "look", type = "string", default = "square",
			choices = {"square", "round", "ring", "voxel"}},
		color = {cat = "look", type = "string", default = "#ffffff"},
		color2 = {cat = "look", type = "string", default = ""},
		axis = {cat = "look", type = "position", default = {0, 1, 0}},
		offset = {cat = "look", type = "position", default = {0, 0, 0}},
		spread = {cat = "look", type = "number", default = 180, min = 0, max = 180},
		speed_min = {cat = "look", type = "number", default = 1, min = 0, max = 60},
		speed_max = {cat = "look", type = "number", default = 2, min = 0, max = 60},
		gravity = {cat = "look", type = "number", default = 9, min = -50, max = 50},
		drag = {cat = "look", type = "number", default = 0, min = 0, max = 20},
		ttl_min = {cat = "look", type = "number", default = 0.4, min = 0.05, max = 10},
		ttl_max = {cat = "look", type = "number", default = 0.8, min = 0.05, max = 10},
		size_min = {cat = "look", type = "number", default = 0.06, min = 0.01, max = 8},
		size_max = {cat = "look", type = "number", default = 0.1, min = 0.01, max = 8},
		grow = {cat = "look", type = "number", default = 0, min = -20, max = 100},
		fade = {cat = "look", type = "number", default = 0.3, min = 0, max = 1},
		box = {cat = "look", type = "number", default = 0, min = 0, max = 16},
		spin = {cat = "look", type = "number", default = 0, min = 0, max = 1440},
		land = {cat = "look", type = "bool", default = false},
		light_color = {cat = "look", type = "string", default = "#fff0c0"},
		light_range = {cat = "look", type = "number", default = 8, min = 0.5, max = 40},
		light_brightness = {cat = "look", type = "number", default = 2, min = 0, max = 8},
		light_time = {cat = "look", type = "number", default = 0, min = 0, max = 2},
		flash_color = {cat = "look", type = "string", default = "#ff2020"},
		flash_time = {cat = "look", type = "number", default = 0, min = 0, max = 2},
		arc_color = {cat = "look", type = "string", default = "#ff2020"},
		arc_time = {cat = "look", type = "number", default = 0, min = 0, max = 10},
	},
	state = {
		running = {default = false},
		left = {default = 0},
		value = {default = false},
		color = {default = ""},
	},
	about = {
		what = "Particles and a light the clients show, on a signal or a world event.",
		inputs = {
			burst = "One burst. Value: where, if its where is \"value\": a position, entity, player or team.",
			on = "A burst now and then every few seconds, until off. Value: as burst's.",
			off = "Stops the bursts that on started.",
			color = "Changes its colour from now on. Value: a team's name or #rrggbb; \"\" its own.",
		},
		outputs = {
			fired = "A burst went off. Value: where, a position.",
		},
	},
	inputs = {burst = "any", on = "any", off = "none", color = "string"},
	outputs = {fired = "position"},
	on_input = function(c, input, value)
		if input == "burst" then
			fire(c, value)
		elseif input == "on" then
			c.state.running = true
			c.state.value = value == nil and false or value
			c.state.left = c.params.repeats
			fire(c, value)
			c:after(c.params.every, "next")
		elseif input == "off" then
			c.state.running = false
			c:after(nil, "next")
		elseif type(value) == "string" then
			local t = team_named(c, value)
			c.state.color = t and t.params.color or value
		end
	end,
	on_timer = function(c)
		local s = c.state
		if not s.running then
			return
		end
		if c.params.repeats > 0 then
			s.left = s.left - 1
			if s.left <= 0 then
				s.running = false
				return
			end
		end
		local v = s.value
		if v == false then
			v = nil
		end
		fire(c, v)
		c:after(c.params.every, "next")
	end,
	on_event = function(c, ev)
		local p = c.params
		local o = {at = ev.pos, voxels = ev.voxels, player = ev.player,
			from = ev.from}
		if p.along_hit and ev.dir then
			o.dir = ev.dir
		end
		if p.scale_by_damage and ev.share then
			o.count = p.count > 0 and math.max(1, math.ceil(p.count * ev.share)) or 0
		end
		if p.team_color and ev.player then
			o.color = color_of(team_of(c, ev.player))
		end
		burst(c, o)
		c:emit("fired", ev.pos)
	end,
}
