-- Buildat: builtin/luanti/lua/dig.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- Digging, placing and punching, what the items look like, the dig
-- properties and the node searches. Run by bootstrap.lua with the five of
-- its locals this reads ([SPLITS]: moved out as it was).

local __find_nodes, __get_region, id_matcher, ids_and_names, to_pos = ...

--
-- Digging, placing and punching, with nobody doing them
--
-- The three things a player's actions come to, and what a mod calls when it
-- wants the same thing to happen without one. Luanti's own l_dig_node,
-- l_place_node and l_punch_node: each makes the pointed thing a player's
-- action would have made, hands it to the vendored builtin with a nil actor,
-- and lets that run the callbacks. So `on_dig`, `can_dig`, `after_dig_node`,
-- `on_construct`, `after_place_node`, the drop list and the registered
-- on_dignodes and on_placenodes are the builtin's own and behave as they do
-- in Luanti, rather than being written again here.
--
-- Where a dig's drops go: core.handle_node_drops() puts them in the digger's
-- inventory when the digger is a player, and hands the rest to
-- core.add_item(), which is the vendored builtin's own item entity now that
-- there are objects for it to be. With no digger there is no inventory to put
-- anything in, so everything a dig drops is spawned.

local function pointed_at(pos)
	return {
		type = "node",
		above = {x = pos.x, y = pos.y, z = pos.z},
		under = {x = pos.x, y = pos.y - 1, z = pos.z},
	}
end

-- core.__item_images() -> {item name, expression, item name, ...}
--
-- What each item looks like in an inventory, as the texture modifier
-- expression the client composes: the item's inventory_image, or the first
-- tile of the node it places. The client asks for these once, the way it
-- asks for the node tiles' expressions.
--
-- A node that is a cube is drawn as the little cube Luanti draws: the three
-- faces a viewer sees, sheared by the client. What crosses for one is the
-- marker "\1cube\1" and then the three expressions, the sides already
-- carrying the multiply that darkens them.
--
-- simplified: a node that is not a plain cube -- a nodebox, a plant, a mesh
-- -- is one of its tiles, flat. What those look like is their own shape, and
-- a flat tile is a better lie than a cube would be.
-- The same for one item, which is what an object that is a dropped item
-- wants; see appearance_of() in lua/entity.lua
-- Which drawtypes an inventory draws as a cube. The names are Luanti's own
-- and a node that says nothing is "normal".
local CUBE_DRAWTYPES = {
	normal = true, liquid = true, flowingliquid = true, glasslike = true,
	allfaces = true, allfaces_optional = true, glasslike_framed = true,
	glasslike_framed_optional = true,
}

-- One of a node's tiles as the expression it is, with Luanti's own rule for
-- a list shorter than six: the last one stands for the rest
local function one_tile(tiles, i)
	if type(tiles) ~= "table" or #tiles == 0 then
		return nil
	end
	local tile = tiles[math.min(i, #tiles)]
	if type(tile) == "table" then
		tile = tile.name or tile.image
	end
	if type(tile) ~= "string" or tile == "" then
		return nil
	end
	return tile
end

-- The face's own tile with its overlay over it, the way tile_names() builds
-- the world's: an item that places devtest's dirt_with_grass is a grassy
-- cube in the inventory and not a dirt one
local function tile_of(def, i)
	local tile = one_tile(def.tiles or def.tile_images, i)
	if tile == nil then
		return nil
	end
	local overlay = one_tile(def.overlay_tiles, i)
	if overlay ~= nil then
		return tile .. "^(" .. overlay .. ")"
	end
	return tile
end

-- The tiles are +Y, -Y, +X, -X, +Z, -Z: the top and the two faces that point
-- at a viewer standing off the +X +Z corner. The shades are Luanti's --
-- 214/256 and 171/256 of the top's own brightness, which as a multiply is
-- #d5d5d5 and #aaaaaa -- and they go on the tile rather than on the canvas,
-- because a multiply over the canvas would darken what is already drawn on
-- it.
local function cube_expr(def)
	if not CUBE_DRAWTYPES[def.drawtype or "normal"] then
		return nil
	end
	local top, left, right = tile_of(def, 1), tile_of(def, 5), tile_of(def, 3)
	if top == nil or left == nil or right == nil then
		return nil
	end
	return "\1cube\1" .. top .. "\1" .. left .. "^[multiply:#d5d5d5" ..
			"\1" .. right .. "^[multiply:#aaaaaa"
end

-- A node box's or a mesh's node, which Luanti's inventory draws as its
-- shape ([VL_INV_PARITY]): "\1shape\1", "b:" and the fixed boxes
-- ("x0,y0,z0,x1,y1,z1;...", nodes) or "m:" and the mesh, then the six
-- tiles. The client projects it (extensions/luanti_client/res/
-- item_shape.lua).
local function shape_expr(def)
	local geom
	local nb = def.node_box
	if def.drawtype == "nodebox" and type(nb) == "table" and
			(nb.type == "fixed" or nb.type == "leveled") and
			type(nb.fixed) == "table" then
		local boxes = type(nb.fixed[1]) == "number" and {nb.fixed} or nb.fixed
		local parts = {}
		for _, b in ipairs(boxes) do
			if type(b) ~= "table" or #b < 6 then
				return nil
			end
			local n = {}
			for i = 1, 6 do
				n[i] = tonumber(b[i])
				if not n[i] then
					return nil
				end
			end
			parts[#parts + 1] = string.format("%.4g,%.4g,%.4g,%.4g,%.4g,%.4g",
					math.min(n[1], n[4]), math.min(n[2], n[5]),
					math.min(n[3], n[6]), math.max(n[1], n[4]),
					math.max(n[2], n[5]), math.max(n[3], n[6]))
		end
		if #parts == 0 then
			return nil
		end
		geom = "b:" .. table.concat(parts, ";")
	elseif def.drawtype == "mesh" and type(def.mesh) == "string" and
			def.mesh ~= "" and not def.mesh:find("\1") then
		geom = "m:" .. def.mesh
	else
		return nil
	end
	local tiles = {}
	for i = 1, 6 do
		tiles[i] = tile_of(def, i)
		if tiles[i] == nil or tiles[i] == "" then
			return nil
		end
	end
	return "\1shape\1" .. geom .. "\1" .. table.concat(tiles, "\1")
end

-- What one item is drawn as: its own picture, the little cube if it places
-- one, its shape if it is a node box or a mesh, its first tile, or what it
-- looks like in a hand
local function item_image_expr(def)
	local expr = def.inventory_image
	if expr ~= nil and expr ~= "" then
		return expr
	end
	expr = cube_expr(def) or shape_expr(def)
	if expr ~= nil then
		return expr
	end
	expr = tile_of(def, 1)
	if expr ~= nil and expr ~= "" then
		return expr
	end
	return def.wield_image
end

function core.__item_image_of(name)
	local def = core.registered_items[name]
	if def == nil then
		return nil
	end
	local expr = item_image_expr(def)
	if expr == nil or expr == "" then
		return nil
	end
	return expr
end

function core.__item_images()
	local out = {}
	local function add(name, expr)
		if type(expr) == "string" and expr ~= "" then
			out[#out + 1] = name
			out[#out + 1] = expr
		end
	end
	for name, def in pairs(core.registered_items) do
		if name ~= "" then
			add(name, item_image_expr(def))
		end
	end
	return out
end

-- core.__wield_meshes() -> {item name, mesh "\1" tile "\1" tile ..., ...}
--
-- What a hand holding a mesh node draws: official's WieldMeshSceneNode
-- draws the node's own mesh, in its tiles, for a node whose drawtype is
-- "mesh" and that has no wield_image -- VoxeLibre's hand is one, the
-- player's skin on an arm ([WIELD_MESH]). The tiles are the expressions
-- in the mesh's material order.
function core.__wield_meshes()
	local out = {}
	for name, def in pairs(core.registered_items) do
		if name ~= "" and def.drawtype == "mesh" and
				type(def.mesh) == "string" and def.mesh ~= "" and
				(def.wield_image == nil or def.wield_image == "") then
			local parts = {def.mesh}
			local tiles = def.tiles or def.tile_images
			for i = 1, math.max(1, type(tiles) == "table" and #tiles or 0) do
				parts[#parts + 1] = tile_of(def, i) or ""
			end
			out[#out + 1] = name
			out[#out + 1] = table.concat(parts, "\1")
		end
	end
	return out
end

-- core.__item_palettes() -> {item name, palette texture, ...}
--
-- Which palette an item's definition names, for a stack that carries a
-- palette_index of its own ([ITEM_META_LOOK]): the client reads the colour
-- out of the picture itself, since the palette is media it already has.
function core.__item_palettes()
	local out = {}
	for name, def in pairs(core.registered_items) do
		if name ~= "" and type(def.palette) == "string" and
				def.palette ~= "" then
			out[#out + 1] = name
			out[#out + 1] = def.palette
		end
	end
	return out
end

-- core.__dig_props() -> {record, record, ...}
--
-- What a client needs to work a dig out for itself: how long it takes, how
-- far it reaches and what the slot under the mouse is called. Luanti's
-- client does that arithmetic rather than asking, because a round trip in
-- front of every dig is what a game stuttering looks like; the server
-- checks again when the dig completes, because it trusts the client with
-- neither.
--
-- Two kinds of record, each one string of tab-separated fields:
--
--   i <name> <range> <short description> <full_punch_interval>
--      <group>:<maxlevel>:<uses>:<rating>=<time>,<rating>=<time> ...
--   n <name> <group>=<rating>,<group>=<rating>
--   d <name> <node_placement_prediction> <node_dig_prediction> <flags>
--   t <name> <modes>
--
-- The d record is what a client predicts with ([PREDICTION]): the item's
-- placement prediction (Luanti's default, the item's own node for a node
-- and nothing for the rest), the node's dig prediction ("air" unless the
-- definition says otherwise) and flags among "r" (has on_rightclick,
-- which a click without sneak uses instead of placing), "b" (buildable_to,
-- placed into rather than against), "p" (a paramtype2 the placement
-- works out from the look, which is left to the server) and "w"
-- (walkable, which is not predicted into the player's own box). Items whose
-- record would say nothing -- no node, no prediction -- have none.
--
-- The t record is the item's touch_interaction ([TOUCH_PARITY]), resolved
-- as Luanti's client resolves "user": three letters for pointed_nothing,
-- pointed_node and pointed_object, "l" a long tap digs and a short one
-- places, "s" the other way round. Only an item that differs from "lls"
-- (no touch_interaction and no on_use) has one.
--
-- An item with no tool_capabilities has an empty fourth field and no
-- groupcap fields after it, which is what says it has none: the hand's are
-- used in its place, and that is the client's rule to apply.
--
-- Only the groups some tool's groupcap rates cross, plus the two the dig
-- arithmetic reads by name. A game's nodes carry groups for its own mods to
-- read -- VoxeLibre's 2536 nodes times its full group table is a large
-- packet of nothing, and none of it is ever looked at here.
local function dig_field(s)
	return (tostring(s):gsub("[\t\r\n]", " "))
end

-- What Luanti's ItemStack::getShortDescription() answers with: the item's
-- own short_description, or the first line of its description
local function short_description(def)
	local s = def.short_description
	if type(s) ~= "string" or s == "" then
		s = def.description
	end
	if type(s) ~= "string" then
		return ""
	end
	return string.match(s, "^[^\n]*") or ""
end

function core.__dig_props()
	local out = {}
	local rated = {level = true, dig_immediate = true}
	for name, def in pairs(core.registered_items) do
		local caps = def.tool_capabilities
		local fields = {"i", name, tostring(tonumber(def.range) or -1),
				dig_field(short_description(def)),
				caps and tostring(tonumber(caps.full_punch_interval) or 1) or ""}
		local groupcaps = caps and caps.groupcaps or nil
		if type(groupcaps) == "table" then
			for group, cap in pairs(groupcaps) do
				rated[group] = true
				local times = {}
				if type(cap.times) == "table" then
					for rating, time in pairs(cap.times) do
						times[#times + 1] = tostring(rating) .. "=" ..
								tostring(time)
					end
				end
				fields[#fields + 1] = group .. ":" ..
						tostring(tonumber(cap.maxlevel) or 1) .. ":" ..
						tostring(tonumber(cap.uses) or 0) .. ":" ..
						table.concat(times, ",")
			end
		end
		out[#out + 1] = table.concat(fields, "\t")
	end
	for name, def in pairs(core.registered_items) do
		local ti = def.touch_interaction
		local modes = ""
		for _, kind in ipairs({"nothing", "node", "object"}) do
			local m = type(ti) == "table" and ti["pointed_" .. kind] or ti
			if m ~= "long_dig_short_place" and m ~= "short_dig_long_place" then
				-- "user": a punch by a short tap, for an item that punches
				m = kind == "object" and def.on_use == nil and
						"short_dig_long_place" or "long_dig_short_place"
			end
			modes = modes .. m:sub(1, 1)
		end
		if modes ~= "lls" then
			out[#out + 1] = "t\t" .. name .. "\t" .. modes
		end
	end
	local placed_param2 = {facedir = true, wallmounted = true,
			colorfacedir = true, colorwallmounted = true, ["4dir"] = true,
			color4dir = true}
	for name, def in pairs(core.registered_items) do
		local node = core.registered_nodes[name]
		local place = def.node_placement_prediction
		if place == nil then
			place = node and name or ""
		end
		if node or place ~= "" then
			local flags = ""
			if node and node.on_rightclick then flags = flags .. "r" end
			if node and node.buildable_to then flags = flags .. "b" end
			if node and placed_param2[node.paramtype2] then
				flags = flags .. "p"
			end
			if node and node.walkable ~= false then flags = flags .. "w" end
			out[#out + 1] = "d\t" .. name .. "\t" .. dig_field(place) .. "\t" ..
					dig_field(node and node.node_dig_prediction or "air") ..
					"\t" .. flags
		end
	end
	-- **What a node sounds like underfoot** ([NO_SOUND]'s footsteps,
	-- 2026-09-25): official Luanti plays these in the engine off the
	-- player's own movement, not from a mod calling sound_play, so the
	-- client needs the node's own spec. The group is resolved here --
	-- the module is what knows which files it serves -- and the choice
	-- per step is the client's.
	--
	-- **And what it sounds like dug and placed**, which are the player's
	-- own two ([NO_SOUND], 2026-09-25): the builtin plays those with
	-- `exclude_player = the digger`, because official's client plays its
	-- own -- so without this the one player who did it hears nothing,
	-- which is what digging in this tree sounded like.
	--
	--   s <name> <gain> <pitch> <file>,<file>,...   underfoot
	--   g <name> <gain> <pitch> <file>,...          dug
	--   q <name> <gain> <pitch> <file>,...          placed
	--
	-- **And the swing's** ([DIG_SWING_SOUND]): official's client plays
	-- the node's dig sound and the wielded item's use sound as each
	-- swing crosses 0.15 (Camera::step, SoundMaker::cameraPunchLeft).
	--
	--   h <name> <gain> <pitch> <file>,...          dig; no files is silent
	--   h __group:<group> 0.5 1 <file>,...          "__group"'s, by the dig's
	--                                               main group
	--   u <item> <gain> <pitch> <file>,...          sound_use
	--   v <item> <gain> <pitch> <file>,...          sound_use_air
	--
	-- A node with no h record digs to "__group", which is Luanti's default
	-- for sounds.dig: default_dig_<the group the dig went by>, at 0.5.
	--
	-- "g" and not "d": "d" is the dig prediction's own record above, and
	-- a second meaning for it parsed as a prediction with a gain where
	-- its node name should be (2026-09-25, an hour of "0 with a dug
	-- sound" while the client read them as predictions).
	local function sound_record(kind, name, spec)
		if type(spec) == "string" then
			spec = {name = spec}
		end
		if type(spec) ~= "table" or type(spec.name) ~= "string" or
				not __luanti_sound_files then
			return
		end
		local files = spec.name ~= "" and __luanti_sound_files(spec.name)
		if type(files) ~= "table" or #files == 0 then
			-- Silence said on purpose is the dig's to know, since none
			-- at all is "__group"
			if kind == "h" then
				out[#out + 1] = "h\t" .. name .. "\t0\t1\t"
			end
			return
		end
		out[#out + 1] = kind .. "\t" .. name .. "\t" ..
				tostring(tonumber(spec.gain) or 1.0) .. "\t" ..
				tostring(tonumber(spec.pitch) or 1.0) .. "\t" ..
				table.concat(files, ",")
	end
	local sound_kinds = {{"s", "footstep"}, {"g", "dug"}, {"q", "place"},
			{"h", "dig"}}
	for name, def in pairs(core.registered_nodes) do
		for _, kind in ipairs(sound_kinds) do
			local spec = type(def.sounds) == "table" and def.sounds[kind[2]]
			if not (kind[1] == "h" and (spec == "__group" or
					type(spec) == "table" and spec.name == "__group")) then
				sound_record(kind[1], name, spec)
			end
		end
	end
	for group in pairs(rated) do
		sound_record("h", "__group:" .. group,
				{name = "default_dig_" .. group, gain = 0.5})
	end
	for name, def in pairs(core.registered_items) do
		sound_record("u", name, def.sound_use)
		sound_record("v", name, def.sound_use_air)
	end
	for name, def in pairs(core.registered_nodes) do
		local groups = def.groups
		if type(groups) == "table" then
			local pairs_out = {}
			for group, rating in pairs(groups) do
				if rated[group] and type(rating) == "number" then
					pairs_out[#pairs_out + 1] = group .. "=" .. tostring(rating)
				end
			end
			if #pairs_out > 0 then
				out[#out + 1] = "n\t" .. name .. "\t" ..
						table.concat(pairs_out, ",")
			end
		end
		-- And the colour painted over the screen while the camera is in
		-- the node -- Luanti's post_effect_color, {a, r, g, b} in 0..255
		-- -- for a node that has one; and whether it is solid, which is
		-- black in the same place. The client half's post_effect_of().
		local pe = def.post_effect_color
		if type(pe) == "table" and (tonumber(pe.a) or 0) > 0 then
			out[#out + 1] = "p\t" .. name .. "\t" ..
					table.concat({tostring(tonumber(pe.a) or 0),
					tostring(tonumber(pe.r) or 0), tostring(tonumber(pe.g) or 0),
					tostring(tonumber(pe.b) or 0)}, ",")
		end
	end
	return out
end

-- core.get_dig_params(groups, tool_capabilities, [wear])
--
-- How long a tool takes on a node and what the use costs it, which is what
-- core.node_dig() asks before it digs anything -- so a dig by a player goes
-- through here and a dig by nobody does not. Luanti's own is getDigParams()
-- in src/tool.cpp and this is the same walk over the tool's groupcaps:
-- the group that digs the node fastest wins, a tool whose maxlevel is more
-- than one above the node's level is faster still, and dig_immediate is a
-- fixed time that costs nothing.
--
local function group_rating(groups, name)
	local v = groups and groups[name]
	return type(v) == "number" and v or 0
end

function core.get_dig_params(groups, tool_capabilities, wear)
	local caps = type(tool_capabilities) == "table" and
			tool_capabilities.groupcaps or nil
	-- The fixed time is the group's own unless the tool says what it does
	-- about dig_immediate, which is Luanti's order
	if not (caps and caps.dig_immediate) then
		local immediate = group_rating(groups, "dig_immediate")
		if immediate == 2 then
			return {diggable = true, time = 0.5, wear = 0}
		elseif immediate == 3 then
			return {diggable = true, time = 0, wear = 0}
		end
	end
	local level = group_rating(groups, "level")
	local diggable = false
	local best_time = 0
	local best_wear = 0
	for name, cap in pairs(caps or {}) do
		local leveldiff = (tonumber(cap.maxlevel) or 1) - level
		local rating = group_rating(groups, name)
		local time = leveldiff >= 0 and cap.times and cap.times[rating] or nil
		if time then
			if leveldiff > 1 then
				time = time / leveldiff
			end
			if not diggable or time < best_time then
				diggable = true
				best_time = time
				-- A tool used above its level lasts longer, which is the
				-- same three-to-the-leveldiff Luanti scales its uses by,
				-- and no tool has more uses than the wear range has room
				-- for
				local uses = math.min(65535,
						(tonumber(cap.uses) or 0) * 3 ^ leveldiff)
				best_wear = core.__result_wear(uses, wear)
			end
		end
	end
	return {diggable = diggable, time = best_time, wear = best_wear}
end

-- core.get_hit_params(armor_groups, tool_capabilities, [time_from_last_punch],
--         [wear]) -> {hp, wear}
--
-- What a punch takes off and what it costs the tool, which is Luanti's own
-- getHitParams() in src/tool.cpp. Each of the tool's damage groups is
-- rated by the armour group of the same name -- a hundred is "full damage",
-- and armour above that hurts more, not less -- and a punch sooner than the
-- tool's full_punch_interval is worth the fraction of it that has passed.
function core.get_hit_params(armor_groups, tool_capabilities, time_from_last_punch, wear)
	local caps = type(tool_capabilities) == "table" and tool_capabilities or {}
	local interval = tonumber(caps.full_punch_interval) or 1.4
	local since = tonumber(time_from_last_punch) or 1000000
	local fraction = 1.0
	if interval > 0 then
		fraction = since / interval
		if fraction > 1.0 then
			fraction = 1.0
		elseif fraction < 0.0 then
			fraction = 0.0
		end
	end
	local damage = 0
	for name, value in pairs(caps.damage_groups or {}) do
		local armor = group_rating(armor_groups, name)
		damage = damage + (tonumber(value) or 0) * fraction * armor / 100.0
	end
	-- A tool with no punch_attack_uses is not worn by punching at all,
	-- which is what Luanti's zero means
	local uses = tonumber(caps.punch_attack_uses) or 0
	local result_wear = 0
	if uses > 0 and damage > 0 then
		result_wear = core.__result_wear(uses / fraction, wear)
	end
	return {hp = math.floor(damage), wear = result_wear}
end

-- The same dig, by somebody. core.dig_node() is Luanti's own and takes no
-- digger -- it is the dig nobody did -- and a click on a client is a dig
-- somebody did, which is the difference between the drops landing on the
-- ground and landing in their inventory.
function core.__dig_node(pos, digger)
	local node = core.get_node(pos)
	if node.name == "ignore" then
		return false
	end
	-- A player digs what they could reach, and with interact; the node goes
	-- back to their client either way, as below
	if digger and core.__may_interact and
			not core.__may_interact(digger, pos) then
		core.swap_node(pos, node)
		return false
	end
	-- What official's server refuses: a node that neither what is in hand
	-- nor the hand digs (Server::handleCommand_Interact) -- air among
	-- them, which a client digs when a chunk sent before its dig showed
	-- it the node again
	if digger and digger.get_wielded_item then
		local groups = (core.registered_nodes[node.name] or {}).groups or {}
		local stack = digger:get_wielded_item()
		local inv = digger.get_inventory and digger:get_inventory()
		local hand = inv and inv:get_stack("hand", 1) or ItemStack("")
		if not core.get_dig_params(groups, stack:get_tool_capabilities(),
					stack:get_wear()).diggable and
				not core.get_dig_params(groups,
					hand:get_tool_capabilities()).diggable then
			core.swap_node(pos, node)
			return false
		end
	end
	local dug = core.node_dig(pos, node, digger) and true or false
	-- The node as it is now goes back to the clients whatever happened,
	-- so a client that predicted the dig ([PREDICTION]) is put right when
	-- the dig was refused: written unchanged, the chunk is committed and
	-- sent again (Luanti's server sends the node back the same way)
	if digger then
		core.swap_node(pos, core.get_node(pos))
	end
	return dug
end

function core.dig_node(pos)
	return core.__dig_node(pos, nil)
end

-- The same punch, by somebody: what the button going down comes to, before
-- the dig it is the start of. A mod's on_punch is what hears it, and a node
-- that is dug by being punched -- dig_immediate -- is dug by the dig that
-- follows rather than here.
function core.__punch_node(pos, puncher)
	local node = core.get_node(pos)
	if node.name == "ignore" then
		return false
	end
	if puncher and core.__may_interact and
			not core.__may_interact(puncher, pos) then
		return false
	end
	core.node_punch(pos, node, puncher, pointed_at(pos))
	return true
end

function core.punch_node(pos)
	return core.__punch_node(pos, nil)
end

function core.place_node(pos, node, placer)
	local name = type(node) == "string" and node or node.name
	if name == nil then
		error("place_node(): the node has no name")
	end
	local param2 = type(node) == "table" and node.param2 or nil
	-- Luanti places it as an item so that a node with an on_place of its own
	-- gets it, which is how a mod makes placing one node put down another
	core.item_place(ItemStack(name), placer, pointed_at(pos), param2)
	return true
end

-- Returns positions, counts -- or a table of name to positions when grouped
function core.find_nodes_in_area(minp, maxp, nodenames, grouped)
	local x0, y0, z0 = to_pos(minp)
	local x1, y1, z1 = to_pos(maxp)
	if x1 < x0 or y1 < y0 or z1 < z0 then
		return grouped and {} or {}, {}
	end
	local positions = {}
	local counts = {}
	local by_name = {}
	-- The box is swept in C: which ids are wanted is worked out once here,
	-- and what comes back is the hits and nothing else. The Lua that walked
	-- the box a voxel at a time asking a closure about each was a quarter of
	-- all the Lua VoxeLibre's world generation ran.
	local ids, name_of = ids_and_names(nodenames)
	local flat, hit_ids = __find_nodes(x0, y0, z0, x1, y1, z1, ids)
	for h = 1, #hit_ids do
		local name = name_of[hit_ids[h]]
		local p = {x = flat[h * 3 - 2], y = flat[h * 3 - 1], z = flat[h * 3]}
		if grouped then
			local list = by_name[name]
			if not list then
				list = {}
				by_name[name] = list
			end
			list[#list + 1] = p
		else
			positions[#positions + 1] = p
			counts[name] = (counts[name] or 0) + 1
		end
	end
	if grouped then
		-- Luanti gives an empty list for every name that was asked for
		if type(nodenames) == "string" then
			nodenames = {nodenames}
		end
		for _, n in ipairs(nodenames) do
			if by_name[n] == nil and not string.match(n, "^group:") then
				by_name[n] = {}
			end
		end
		return by_name
	end
	return positions, counts
end

function core.find_nodes_in_area_under_air(minp, maxp, nodenames)
	local matches_id = id_matcher(nodenames)
	local x0, y0, z0 = to_pos(minp)
	local x1, y1, z1 = to_pos(maxp)
	local positions = {}
	if x1 < x0 or y1 < y0 or z1 < z0 then
		return positions
	end
	-- One row above the box as well: "under air" is about the node above
	-- each candidate, and for the box's top row that node is outside it.
	-- A one-row box -- the floor of VoxeLibre's witch hut, asked for at
	-- the cauldron's level minus one -- found nothing before this.
	local ids = __get_region(x0, y0, z0, x1, y1 + 1, z1)
	local air_id = core.get_content_id("air")
	local w = x1 - x0 + 1
	local h = y1 + 1 - y0 + 1
	for z = z0, z1 do
		for x = x0, x1 do
			-- Downwards, so the node above is the one just looked at
			local above_id = ids[(x - x0) + (y1 + 1 - y0) * w +
					(z - z0) * w * h + 1]
			for y = y1, y0, -1 do
				local id = ids[(x - x0) + (y - y0) * w +
						(z - z0) * w * h + 1]
				if above_id == air_id and matches_id(id) then
					positions[#positions + 1] = {x = x, y = y, z = z}
				end
				above_id = id
			end
		end
	end
	return positions
end
-- vim: set noet ts=4 sw=4:
