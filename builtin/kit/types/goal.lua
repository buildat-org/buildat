-- A goal ([KIT_GOALS], stage 7b): something to do, for players and, later,
-- bots: a definition (`kind`) and a location pointer. `kind` "reach": be in
-- the box of cells `size` on from its own place. "use": use the object
-- `target` (its use range and who-may-use rules as ever). "signal": only the
-- input "complete" does it (a counter's reached, a boss's death).
-- It does nothing until activated: "activate" or `autostart` (from the round's
-- start). Active, its `text` is a HUD line ([<action>] each player's key; ""
-- none; lines of one anchor and place stack, a hidden one leaving no gap) and
-- with `marker` it is pointed out over the world (at the box's middle, at
-- `target` for a use, at its own place for a signal; through walls, an arrow
-- at the screen's edge while off the screen). Done, both go and "done" signals.
-- **A quest is a chain of goals**, no type of its own: one's "done" linked to
-- the next one's "activate", a branch two links ("cancel" on the other arm
-- makes it either-or); the prefab kit/quest bundles one.
-- `to` "player" (the default: a tutorial's or a quest's step): each player
-- their own, the player who set a signal off the one it changes; autostart or
-- a signal by no player activates it for everyone, late joiners too, each
-- doing it themselves. "everyone" (co-op): one goal, the first player to do
-- it does it for all, a late joiner seeing where it stands.
-- `audience` "players": a bot does not do it, it passes straight on for one.
-- "bots": no line, no marker
-- for a player, and it passes straight on for them, as if done: its chain goes
-- on. A bot acts on kind, target, size and its place, not on what is written
-- for players.
-- [KIT_GUIDE_BOTS] A bot (kit/bot) walks into a reach goal's box, uses a use
-- goal's target, and for a signal goal uses its `via` (what makes the signal,
-- a lever) once; a signal goal without one leaves a bot stuck. A guide (the
-- prefab kit/guide) is a chain whose lines sit in one window at a corner:
-- one step at a time, the next as each is done.
-- [KIT_GUIDE_BOTS_2] `hud_panel`: a kit/ui_panel its line is drawn in, laid
-- out by the panel (a goal has a place, so it cannot be the panel's child):
-- kit/guide's window, a column panel at the top right that fits its shown
-- step and is gone with none. simplified: no title or step count on it.
-- [KIT_GUIDE_BOTS_2] `target` an entity followed as it moves: a reach goal
-- with one is its box (`size`, level) round the target's place, wherever it
-- goes. `pick` says whose target: "entity" (`target`), "own_team" (the team
-- of the player or bot doing it), "their_team" (the nearest other team);
-- picked per player, so only a bot acts on one (a player's line is the
-- same). Kind "place_item": put what one carries (an entity on them, a
-- flag) at the target: a bot walks there and uses it (a flag's right
-- click); done by a link (the flag's "placed"). `except_own_zone`: a bot
-- leaves the target alone while it lies in its own team's region (a flag it
-- placed). `repeat`: done signals "done" and it stays active, done again
-- and again (a flag taken each time); off, a goal is done once a round for
-- whom it was (a chain's branches may merge on it).
-- [KIT_GOAL_PRIORITIES] Goals are a priority list. `priority`: a bot acts
-- on the active goal of the highest it can act on now (ties: the first by
-- id); a player's lines stack highest first, the top one the main line.
-- `when_holding`: only while one holds an item with that tag ("" always,
-- "none": no "weapon"; a player what is in their hands, a bot anything it
-- has); a player's line is hidden otherwise. `pick` also "nearest_item"
-- (the nearest kit/pickup of an item tagged `item_tag`: a reach goal there
-- picks it up) and "nearest_opponent" (a player or bot of another team).
-- Kind "attack": a bot walks to the target and hits it with the item of
-- its when_holding (its damage, reach and cooldown); "place_item" with a
-- when_holding tag: a bot uses that item at the target (kit/placer's bomb).
-- A player's line is a hint: these kinds and picks are done by bots only.
-- [KIT_GUIDE_STATIONS] A reach or an attack goal's `via` a station (a seat
-- of a vehicle whose movement declares one: kit/sea_vessel's, kit/car's,
-- kit/airship's "helm", kit/turret's "gun"): a bot takes the seat and does
-- it through it, a helm steered into the box, a gun aimed at the target and
-- fired (kit/bot); one held by another is not acted on. A player does it as
-- ever: a reach by being in the box (at the helm, the ship takes them
-- there), an attack by its links. `pick` also "nearest_health": the nearest
-- thing with health (kit/health, hp left) that is no player or bot.
-- simplified: a priority list, not a planner; a reach goal with a picked
-- target other than "entity" is never entered (its box stays at its place)
-- simplified: to "team" is left out (kit/ui_text's way, the members sharing one
-- entry, is the upgrade).
-- simplified: its zone is watched and drawn whatever its `kind` (Kit has no
-- zone by parameter).
--
-- The editor checks the links (editor.lua's NT.goal_check, the inspector and
-- at Publish): a goal nothing activates; and `validate_reachable` on a chain's
-- first goal names its final goal, warned of when no chain of links leads
-- there, the last goal reached and the first cut off named, the final goal
-- drawn on the map. A path of links, not that it can happen
local function key(c, by)
	-- ([KIT_GUIDE_BOTS] a bot's own too, "bot:<id>")
	return c.params.to == "player" and type(by) == "string" and
			(by:match("^player:") or by:match("^bot:")) and by or nil
end

local function active(c, k)
	local o = k and c.state.own[k]
	if o and o.shown ~= nil then
		return o.shown
	end
	return c.state.shown
end

-- Done for k (nil: for everyone)
local function finish(c, k, by)
	-- [KIT_GUIDE_BOTS_2] done again and again, active still
	if c.params["repeat"] then
		c:log("done", k and "for " .. c:name(k) or "for everyone",
				by and "by " .. c:name(by) or "", "(repeats)")
		return c:emit("done", by and c:name(by) or "")
	end
	if k then
		c.state.own[k] = {shown = false, done = true}
	else
		c.state.shown = false
		c.state.done = true
		for p in pairs(c.state.own) do
			c.state.own[p] = {shown = false, done = true}
		end
	end
	c:log("done", k and "for " .. c:name(k) or "for everyone",
			by and "by " .. c:name(by) or "")
	c:emit("done", by and c:name(by) or "")
end

local function activate(c, by)
	local k = key(c, by)
	if c.state.done or (k and c.state.own[k] and c.state.own[k].done) then
		return
	end
	-- [KIT_GUIDE_BOTS] a bot does a bots' goal; a players' one passes straight
	-- on for a bot
	local bot = k ~= nil and k:match("^bot:") ~= nil
	if (c.params.audience == "bots") ~= bot and c.params.audience ~= "everyone" then
		return finish(c, k, by)
	end
	if active(c, k) then
		return
	end
	if k then
		c.state.own[k] = {shown = true}
	else
		c.state.shown = true
		for p, o in pairs(c.state.own) do
			if not o.done then
				c.state.own[p] = nil
			end
		end
	end
	c:log("active", k and "for " .. c:name(k) or "for everyone")
	c:emit("activated")
	-- Already there
	if c.params.kind == "reach" then
		for p in pairs(c.state.inside) do
			if p == k then
				return finish(c, k, by)
			elseif not k then
				local pk = key(c, p)
				if active(c, pk) then
					finish(c, pk, p)
				end
			end
		end
	end
end

return {
	version = 1,
	zone = "size",
	events = "kind",
	gizmo = {shape = "sphere", size = 0.25, color = "#ffe040"},
	marker = {color = "param:marker_color", label = "param:marker_label",
		lift = "param:marker_lift", style = "param:marker_style",
		state = "shown", on = "param:marker", kind = "param:kind",
		target = "param:target", box = "param:size", arrow = true},
	ui = {kind = "text", stack = true, text = "param:text",
		anchor = "param:hud_anchor", x = "param:hud_x", y = "param:hud_y",
		width = "param:hud_width", height = "param:hud_height",
		size = "param:hud_size", color = "param:hud_color",
		background = "param:hud_background", border = "param:hud_border",
		style = "param:hud_style", order = "param:hud_order", prefix = "hud_",
		priority = "param:priority", holding = "param:when_holding"},
	params = {
		kind = {type = "string", default = "reach",
			choices = {"reach", "use", "signal", "place_item", "attack"}},
		size = {type = "position", default = {3, 2, 3}},
		target = {type = "entity", default = 0},
		pick = {type = "string", default = "entity",
			choices = {"entity", "own_team", "their_team", "nearest_item",
			"nearest_opponent", "nearest_health"}},
		item_tag = {type = "string", default = "weapon"},
		priority = {type = "number", default = 0, min = -100, max = 100},
		when_holding = {type = "string", default = ""},
		except_own_zone = {type = "bool", default = false},
		["repeat"] = {type = "bool", default = false},
		via = {type = "entity", default = 0},
		autostart = {type = "bool", default = false},
		to = {type = "string", default = "player",
			choices = {"player", "everyone"}},
		audience = {type = "string", default = "everyone",
			choices = {"everyone", "players", "bots"}},
		validate_reachable = {type = "entity", default = 0},
		text = {cat = "hud", type = "string", default = "Reach the marked place"},
		hud_style = {cat = "hud", type = "string", default = "shapes",
			choices = {"shapes", "plain"}},
		hud_anchor = {cat = "hud", type = "string", default = "top",
			choices = {"top_left",
			"top", "top_right", "left", "center", "right", "bottom_left",
			"bottom", "bottom_right"}},
		hud_x = {cat = "hud", type = "number", default = 0, min = -400,
			max = 400},
		hud_y = {cat = "hud", type = "number", default = 12, min = -400,
			max = 400},
		hud_width = {cat = "hud", type = "number", default = 0, min = 0,
			max = 400},
		hud_height = {cat = "hud", type = "number", default = 0, min = 0,
			max = 400},
		hud_size = {cat = "hud", type = "number", default = 2, min = 0.5,
			max = 30},
		hud_color = {cat = "hud", type = "string", default = "#ffffff"},
		hud_background = {cat = "hud", type = "string", default = "#000000a0"},
		hud_border = {cat = "hud", type = "string", default = "#808080a0"},
		hud_order = {cat = "hud", type = "number", default = 0, min = -40,
			max = 40},
		hud_panel = {cat = "hud", type = "entity", default = 0},
		marker = {cat = "look", type = "bool", default = true},
		marker_style = {cat = "look", type = "string", default = "shapes",
			choices = {"shapes", "plain"}},
		marker_color = {cat = "look", type = "string", default = "#ffe040"},
		marker_label = {cat = "look", type = "string", default = "Goal"},
		marker_lift = {cat = "look", type = "number", default = 1, min = 0,
			max = 20},
	},
	state = {
		shown = {default = false, shared = true},
		-- Done for everyone
		done = {default = false},
		-- Each player's own: {shown, done}
		own = {default = {}, per_player = true},
		-- Who stands in its box, by their `by`
		inside = {default = {}},
	},
	about = {
		group = "Game",
		what = "Something to do, a HUD line and a marker while it is active: reach a box, use an object, or a signal.",
		inputs = {
			activate = "Activates it, for who set this off (to everyone: for all). Value: unused.",
			complete = "Does it, while active, as reaching or using it would. Value: unused.",
			cancel = "Deactivates it, not done: activate may bring it back. Value: unused.",
		},
		outputs = {
			activated = "It became active.",
			done = "It was done. Value: the player's name, or none.",
		},
	},
	inputs = {activate = "any", complete = "any", cancel = "any"},
	outputs = {activated = "none", done = "string:player"},
	on_start = function(c)
		c.state.shown = c.params.autostart and c.params.audience ~= "bots"
		c.state.done = false
		c.state.own = {}
		c.state.inside = {}
		c:log(c.state.shown and "active from the start" or "waits for activate")
	end,
	on_params = function(c, changed)
		if changed.autostart ~= nil and not c.state.done then
			c.state.shown = c.params.autostart and c.params.audience ~= "bots"
		end
	end,
	on_input = function(c, input, _, by)
		if input == "activate" then
			return activate(c, by)
		end
		local k = key(c, by)
		if input == "complete" then
			if active(c, k) then
				finish(c, k, by)
			elseif not k and not c.state.done then
				for _, o in pairs(c.state.own) do
					if o.shown then
						return finish(c, nil, by)
					end
				end
			end
		elseif k then
			if active(c, k) then
				c.state.own[k] = {shown = false}
				c:log("cancelled for", c:name(k))
			end
		else
			c.state.shown = false
			for p, o in pairs(c.state.own) do
				if not o.done then
					c.state.own[p] = nil
				end
			end
			c:log("cancelled for everyone")
		end
	end,
	on_enter = function(c, by)
		c.state.inside[by] = true
		local k = key(c, by)
		if c.params.kind == "reach" and active(c, k) then
			finish(c, k, by)
		end
	end,
	on_leave = function(c, by)
		c.state.inside[by] = nil
	end,
	-- The world event "use": a player used an object
	on_event = function(c, ev, by)
		local k = key(c, by)
		if ev.entity == c.params.target and active(c, k) then
			finish(c, k, by)
		end
	end,
}
