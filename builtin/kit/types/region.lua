-- A region ([KIT] stage 4j): a box of cells (its own and `size` on) with
-- rules: dig, place, enter, pvp and damage. Each rule says who may: all,
-- its owners, everyone else (others) or none ("Red base": dig and place
-- for owners, enter and pvp for all). Its owners (`owner`):
-- nobody, the builders (edit rights), or the players named in `owners`
-- ("alice, bob"); a team's from stage 7b. Where regions overlap the
-- smallest holding the cell decides; outside every region the World's
-- default holds: no digging or placing (a builder in edit mode only), entering, pvp
-- and damage for all.
--
-- Its signals: enable and disable (a disabled region decides nothing),
-- set_owner (the player who set it off owns it: a capture point; a value,
-- a name or names, else), one input a rule taking a bool (that rule for
-- everyone else on or off; the owners keep theirs), resize (a size, {x, y, z}: the
-- region that size from its corner on, over `resize_time` seconds), and
-- dig_out (every cell in it made air, a game change put back as the round
-- ends). "changed" signals a rule's or the owners' change.
--
-- A component on the same entity with an allow(c, player, action, pos)
-- handler is asked first: true or false decides (false's second value is
-- the reason the player is shown), nil leaves it to the rules. Metered as
-- any handler.
--
-- Seen: the editor draws its box and lists its rules; in play a refusal
-- says why ("Protected: no digging here"), and show_border draws its box
-- for the players.
--
-- simplified: Kit has no hits or damage of its own yet: pvp and damage
-- are kept, shown and asked by api.h's allows() for the games that have
-- them
local RULES = {"dig", "place", "enter", "pvp", "damage"}

local function owners_of(c)
	local o = c.params.owner
	if o == "players" then
		local names = {}
		for n in tostring(c.params.owners):gmatch("[^,%s]+") do
			names[#names + 1] = n
		end
		return names
	end
	return o
end

-- Its rules as the host reads them (state.rules): each who may, "all",
-- "owners", "others" or "none"; set only when one changed (a region's
-- runs kept cheap: its state is encoded at each)
local function publish(c, by, what)
	local r, was, changed = {}, c.state.rules, false
	for _, k in ipairs(RULES) do
		local p, o = c.params[k], c.state.others[k]
		local mine = p == "all" or p == "owners"
		local theirs = p == "all" or p == "others"
		if o ~= nil then
			theirs = o
		end
		r[k] = mine and theirs and "all" or mine and "owners" or theirs and
				"others" or "none"
		changed = changed or was[k] ~= r[k]
	end
	if changed then
		c.state.rules = r
	end
	if what then
		c:log(what, by and ("by " .. c:name(by)) or "")
		c:emit("changed", what)
	end
	return r
end

-- A resize's next step: there at once with no resize_time, else a tenth
-- of a second at a time
local function step(c)
	local r = c.state.resize
	if not r then
		return
	end
	local secs = c.params.resize_time
	r.t = secs > 0 and math.min(1, r.t + 0.1 / secs) or 1
	local s = {}
	for i = 1, 3 do
		s[i] = r.from[i] + (r.to[i] - r.from[i]) * r.t
	end
	c.state.size = s
	if r.t >= 1 then
		c.state.resize = false
	else
		c.state.resize = r
		c:after(0.1, "resize")
	end
end

local params = {
	size = {type = "position", default = {5, 3, 5}},
	owner = {type = "string", default = "nobody",
		choices = {"nobody", "builders", "players"}},
	owners = {type = "string", default = ""},
	show_border = {type = "bool", default = false},
	resize_time = {type = "number", default = 0, min = 0, max = 3600},
}
local defaults = {dig = "none", place = "none", enter = "all", pvp = "all",
	damage = "all"}
for _, k in ipairs(RULES) do
	params[k] = {type = "string", default = defaults[k],
		choices = {"all", "owners", "others", "none"}}
end

return {
	version = 1,
	region = "size",
	params = params,
	state = {
		enabled = {default = true, shared = true},
		owners = {default = "nobody", shared = true},
		rules = {default = {}, shared = true},
		-- {x, y, z} while resized by a signal (the parameter's otherwise)
		size = {default = false, shared = true},
		-- A rule's column for everyone else as a signal set it
		others = {default = {}},
		-- A resize under way: {from, to, t (0...1)}
		resize = {default = false},
	},
	gizmo = {shape = "box", size = 0.2, color = "#c08040"},
	inputs = {enable = "none", disable = "none", set_owner = "any",
		dig = "bool", place = "bool", enter = "bool", pvp = "bool",
		damage = "bool", resize = "position", dig_out = "none"},
	outputs = {changed = "string"},
	on_start = function(c)
		-- (the state at its start: a fresh one's defaults, or Stop's)
		c.state.owners = owners_of(c)
		if next(c.state.others) then
			c.state.others = {}
		end
		if c.state.size then
			c.state.size = false
		end
		if c.state.resize then
			c.state.resize = false
		end
		local r = publish(c)
		-- Its rules told: who may
		local t = {}
		for i, k in ipairs(RULES) do
			t[i] = k .. " " .. r[k]
		end
		c:log("holds", table.concat(t, ", "))
	end,
	on_timer = function(c, name)
		if name == "resize" then
			step(c)
		end
	end,
	on_params = function(c)
		c.state.owners = owners_of(c)
		publish(c)
	end,
	on_input = function(c, input, value, by)
		if input == "dig_out" then
			c:set_voxel("air")
			c:log("digs its box out by", c:name(by))
		elseif input == "enable" or input == "disable" then
			c.state.enabled = input == "enable"
			publish(c, by, input .. "d")
		elseif input == "set_owner" then
			if type(value) == "string" or type(value) == "table" then
				c.state.owners = value
			elseif by and by:match("^player:") then
				c.state.owners = {c:name(by)}
			end
			publish(c, by, "owner")
		elseif input == "resize" then
			local from = c.state.size or c.params.size
			c.state.resize = {from = {from[1], from[2], from[3]},
				to = {value[1], value[2], value[3]}, t = 0}
			step(c)
			publish(c, by, "resized")
		else
			local o = c.state.others
			o[input] = value == true
			c.state.others = o
			publish(c, by, input .. (value and " on" or " off") ..
					" for everyone")
		end
	end,
}
