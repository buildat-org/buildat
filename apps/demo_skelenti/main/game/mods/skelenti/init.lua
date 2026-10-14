-- Buildat: apps/demo_skelenti/main/game/mods/skelenti/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- skelenti's Luanti game, the whole of it: the terrain, digging and
-- placing, the craft ladder up to diamond, a crafting table and a
-- furnace, torches, food and drowning. The HUD, the inventory's
-- drawing and the mobs are not here: they are the app's, in Buildat
-- (main.cpp, client_lua/), and reach the game through the bridge.
-- Textures: Pixel Perfection by XSSheep, CC BY-SA 4.0, as VoxeLibre has
-- them (README.md).

local function T(name) return "skelenti_" .. name .. ".png" end
local GRASS = "^[multiply:#79c05a"
-- VoxeLibre tints its water by a palette; one blue here
local WATER = T"water" .. "^[multiply:#3f76e4"

--
-- Nodes
--

core.register_node("skelenti:stone", {description = "Stone",
	tiles = {T"stone"}, groups = {cracky = 3, stone = 1},
	drop = "skelenti:cobble"})
core.register_node("skelenti:cobble", {description = "Cobblestone",
	tiles = {T"cobble"}, groups = {cracky = 3, stone = 1}})
core.register_node("skelenti:dirt", {description = "Dirt",
	tiles = {T"dirt"}, groups = {crumbly = 3, soil = 1}})
core.register_node("skelenti:grass", {description = "Grass Block",
	tiles = {T"grass_top" .. GRASS, T"dirt",
		T"dirt" .. "^(" .. T"grass_side_overlay" .. GRASS .. ")"},
	groups = {crumbly = 3, soil = 1}, drop = "skelenti:dirt"})
core.register_node("skelenti:sand", {description = "Sand",
	tiles = {T"sand"}, groups = {crumbly = 3, falling_node = 1}})
core.register_node("skelenti:gravel", {description = "Gravel",
	tiles = {T"gravel"}, groups = {crumbly = 2, falling_node = 1}})
core.register_node("skelenti:tree", {description = "Log",
	tiles = {T"tree_top", T"tree_top", T"tree"}, paramtype2 = "facedir",
	on_place = core.rotate_node, groups = {choppy = 2, tree = 1}})
core.register_node("skelenti:wood", {description = "Planks",
	tiles = {T"wood"}, groups = {choppy = 3, wood = 1}})
core.register_node("skelenti:leaves", {description = "Leaves",
	drawtype = "allfaces_optional", tiles = {T"leaves" .. GRASS},
	paramtype = "light", groups = {snappy = 3, leaves = 1},
	drop = {max_items = 1, items = {{items = {"skelenti:apple"}, rarity = 12}}}})
core.register_node("skelenti:water_source", {description = "Water",
	drawtype = "liquid", waving = 3,
	tiles = {{name = WATER, animation = {type = "vertical_frames",
		aspect_w = 16, aspect_h = 16, length = 2.0}}},
	use_texture_alpha = "blend", paramtype = "light", walkable = false,
	pointable = false, diggable = false, buildable_to = true,
	drowning = 1, liquidtype = "source",
	liquid_alternative_flowing = "skelenti:water_flowing",
	liquid_alternative_source = "skelenti:water_source",
	liquid_viscosity = 1, post_effect_color = {a = 110, r = 30, g = 60, b = 90},
	groups = {water = 3, liquid = 3}})
core.register_node("skelenti:water_flowing", {description = "Flowing Water",
	drawtype = "flowingliquid", tiles = {WATER .. "^[verticalframe:16:0"},
	special_tiles = {
		{name = WATER .. "^[verticalframe:16:0", backface_culling = false},
		{name = WATER .. "^[verticalframe:16:0", backface_culling = true}},
	use_texture_alpha = "blend", paramtype = "light", paramtype2 = "flowingliquid",
	walkable = false, pointable = false, diggable = false, buildable_to = true,
	drowning = 1, liquidtype = "flowing",
	liquid_alternative_flowing = "skelenti:water_flowing",
	liquid_alternative_source = "skelenti:water_source",
	liquid_viscosity = 1, post_effect_color = {a = 110, r = 30, g = 60, b = 90},
	groups = {water = 3, liquid = 3, not_in_creative_inventory = 1}})
core.register_node("skelenti:coal_ore", {description = "Coal Ore",
	tiles = {T"coal_ore"}, groups = {cracky = 3}, drop = "skelenti:coal"})
core.register_node("skelenti:iron_ore", {description = "Iron Ore",
	tiles = {T"iron_ore"}, groups = {cracky = 2}})
core.register_node("skelenti:diamond_ore", {description = "Diamond Ore",
	tiles = {T"diamond_ore"}, groups = {cracky = 1},
	drop = "skelenti:diamond"})
core.register_node("skelenti:bone_block", {description = "Bone Block",
	tiles = {T"bone_block_top", T"bone_block_top", T"bone_block_side"},
	groups = {cracky = 2}})
core.register_node("skelenti:torch", {description = "Torch",
	drawtype = "torchlike", tiles = {T"torch"}, inventory_image = T"torch",
	wield_image = T"torch", paramtype = "light", sunlight_propagates = true,
	walkable = false, light_source = 13,
	selection_box = {type = "fixed", fixed = {-0.1, -0.5, -0.1, 0.1, 0.1, 0.1}},
	groups = {snappy = 3, dig_immediate = 3, attached_node = 1}})

-- A form the app draws itself, in Buildat's UI (client_lua/ui.lua):
-- the node's formspec is only its name, and the module's form stage
-- hands it to the app with the node's place
local function app_form(name)
	return function(pos)
		core.get_meta(pos):set_string("formspec", "label[0,0;" .. name .. "]")
	end
end
core.register_node("skelenti:table", {description = "Crafting Table",
	tiles = {T"table_top", T"wood", T"table_side", T"table_side",
		T"table_side", T"table_front"},
	paramtype2 = "facedir", groups = {choppy = 2},
	on_construct = app_form("skelenti_table")})

--
-- The furnace: src, fuel and dst, a second a step
--
local function furnace_step(pos)
	local meta = core.get_meta(pos)
	local inv = meta:get_inventory()
	local src = inv:get_stack("src", 1)
	local cooked, after = core.get_craft_result({method = "cooking",
			width = 1, items = {src}})
	local cookable = not src:is_empty() and cooked.time > 0 and
			inv:room_for_item("dst", cooked.item)
	local fuel_left = meta:get_float("fuel_left")
	if cookable and fuel_left <= 0 then
		local fuel, rest = core.get_craft_result({method = "fuel", width = 1,
				items = {inv:get_stack("fuel", 1)}})
		if fuel.time > 0 then
			fuel_left = fuel.time
			inv:set_stack("fuel", 1, rest.items[1])
		end
	end
	local t = 0
	if fuel_left > 0 then
		fuel_left = fuel_left - 1
		if cookable then
			t = meta:get_float("src_time") + 1
			if t >= cooked.time then
				inv:add_item("dst", cooked.item)
				inv:set_stack("src", 1, after.items[1])
				core.log("action", "skelenti: the furnace made " ..
						cooked.item:to_string())
				t = 0
			end
		end
	end
	meta:set_float("src_time", t)
	meta:set_float("fuel_left", fuel_left)
	local node = core.get_node(pos)
	local want = fuel_left > 0 and "skelenti:furnace_active" or "skelenti:furnace"
	if node.name ~= want then
		core.swap_node(pos, {name = want, param2 = node.param2})
	end
	return fuel_left > 0 or cookable
end
local function furnace_def(active)
	return {description = "Furnace",
		tiles = {T"furnace_top", T"furnace_top", T"furnace_side",
			T"furnace_side", T"furnace_side",
			T(active and "furnace_front_active" or "furnace_front")},
		paramtype2 = "facedir", light_source = active and 8 or 0,
		groups = {cracky = 3, not_in_creative_inventory = active and 1 or 0},
		drop = "skelenti:furnace",
		on_construct = function(pos)
			app_form("skelenti_furnace")(pos)
			local inv = core.get_meta(pos):get_inventory()
			inv:set_size("src", 1)
			inv:set_size("fuel", 1)
			inv:set_size("dst", 1)
		end,
		can_dig = function(pos)
			local inv = core.get_meta(pos):get_inventory()
			return inv:is_empty("src") and inv:is_empty("fuel") and
					inv:is_empty("dst")
		end,
		on_timer = furnace_step,
		on_metadata_inventory_put = function(pos)
			core.get_node_timer(pos):start(1)
		end,
		on_metadata_inventory_take = function(pos)
			core.get_node_timer(pos):start(1)
		end,
		allow_metadata_inventory_put = function(_, list, _, stack)
			if list == "dst" then
				return 0
			end
			return stack:get_count()
		end}
end
core.register_node("skelenti:furnace", furnace_def(false))
core.register_node("skelenti:furnace_active", furnace_def(true))

--
-- Items, tools, food
--
local function item(name, desc, image, def)
	def = def or {}
	def.description, def.inventory_image = desc, image or T(name)
	core.register_craftitem("skelenti:" .. name, def)
end
item("stick", "Stick")
item("coal", "Coal")
item("iron_ingot", "Iron Ingot")
item("diamond", "Diamond")
item("bone", "Bone")
item("arrow", "Arrow")
item("apple", "Apple", nil, {on_use = core.item_eat(4)})
item("meat_raw", "Raw Boar Meat", nil, {on_use = core.item_eat(3)})
item("meat_cooked", "Cooked Boar Meat", nil, {on_use = core.item_eat(8)})
-- The end game: what only a deep skeleton drops, and what it makes
-- (proposed; the plan's [LUANTI_APP_EXAMPLE] asks the user to pick)
item("skull", "Deep Skull", T"skull_head" .. "^[sheet:8x4:1,1")
item("crown", "Bone Crown", T"bone_block_top" .. "^(" .. T"skull_head" ..
		"^[sheet:8x4:1,1^[resize:16x16)", {stack_max = 1})

-- The hand: dirt, wood slowly, leaves; no stone
core.register_item(":", {type = "none", wield_image = "blank.png",
	tool_capabilities = {full_punch_interval = 0.5, max_drop_level = 0,
		groupcaps = {
			crumbly = {times = {[2] = 1.5, [3] = 0.8}, uses = 0},
			choppy = {times = {[2] = 4.0, [3] = 3.0}, uses = 0},
			snappy = {times = {[3] = 0.4}, uses = 0},
			oddly_breakable_by_hand = {times = {[3] = 0.5}, uses = 0}},
		damage_groups = {fleshy = 1}}})

-- The ladder: a tier digs the cracky rating its index allows (wood 3,
-- stone 2, iron and diamond 1), and each is faster and lasts longer
local TIERS = {
	{"wood", "Wooden", "skelenti:wood", 1.0, 30, 1},
	{"stone", "Stone", "skelenti:cobble", 0.7, 90, 2},
	{"iron", "Iron", "skelenti:iron_ingot", 0.5, 250, 3},
	{"diamond", "Diamond", "skelenti:diamond", 0.35, 1500, 4},
}
for _, tier in ipairs(TIERS) do
	local key, desc, mat, k, uses, n = unpack(tier)
	local cracky = {[3] = 1.6 * k}
	if n >= 2 then cracky[2] = 2.4 * k end
	if n >= 3 then cracky[1] = 4.0 * k end
	local function tool(kind, name, caps, fleshy, recipe)
		core.register_tool("skelenti:" .. key .. "_" .. kind, {
			description = desc .. " " .. name,
			inventory_image = T(key .. "_" .. kind),
			tool_capabilities = {full_punch_interval = 0.8,
				max_drop_level = n, groupcaps = caps,
				damage_groups = {fleshy = fleshy}},
			groups = {[kind] = 1}})
		core.register_craft({output = "skelenti:" .. key .. "_" .. kind,
				recipe = recipe})
	end
	local m, s = mat, "skelenti:stick"
	tool("pick", "Pickaxe", {cracky = {times = cracky, uses = uses}}, 1 + n,
			{{m, m, m}, {"", s, ""}, {"", s, ""}})
	tool("axe", "Axe", {choppy = {times = {[2] = 2.0 * k, [3] = 1.5 * k},
			uses = uses}}, 2 + n, {{m, m}, {m, s}, {"", s}})
	tool("shovel", "Shovel", {crumbly = {times = {[2] = 0.8 * k,
			[3] = 0.5 * k}, uses = uses}}, n, {{m}, {s}, {s}})
	tool("sword", "Sword", {snappy = {times = {[3] = 0.3 * k}, uses = uses}},
			3 + n, {{m}, {m}, {s}})
end

--
-- Recipes
--
local function craft(output, recipe, kind)
	core.register_craft({output = output, recipe = recipe, type = kind})
end
craft("skelenti:wood 4", {"skelenti:tree"}, "shapeless")
craft("skelenti:stick 4", {{"skelenti:wood"}, {"skelenti:wood"}})
craft("skelenti:table", {{"skelenti:wood", "skelenti:wood"},
		{"skelenti:wood", "skelenti:wood"}})
local c = "skelenti:cobble"
craft("skelenti:furnace", {{c, c, c}, {c, "", c}, {c, c, c}})
craft("skelenti:torch 4", {{"skelenti:coal"}, {"skelenti:stick"}})
craft("skelenti:bone_block", {{"skelenti:bone", "skelenti:bone", "skelenti:bone"},
		{"skelenti:bone", "skelenti:bone", "skelenti:bone"},
		{"skelenti:bone", "skelenti:bone", "skelenti:bone"}})
local k, d, b = "skelenti:skull", "skelenti:diamond", "skelenti:bone_block"
craft("skelenti:crown", {{k, d, k}, {b, k, b}})
core.register_craft({type = "cooking", output = "skelenti:iron_ingot",
		recipe = "skelenti:iron_ore", cooktime = 4})
core.register_craft({type = "cooking", output = "skelenti:meat_cooked",
		recipe = "skelenti:meat_raw", cooktime = 3})
for name, time in pairs({["skelenti:coal"] = 40, ["skelenti:tree"] = 15,
		["skelenti:wood"] = 8, ["skelenti:stick"] = 2}) do
	core.register_craft({type = "fuel", recipe = name, burntime = time})
end

--
-- The terrain: Luanti's own v7 with these nodes
--
core.register_alias("mapgen_stone", "skelenti:stone")
core.register_alias("mapgen_water_source", "skelenti:water_source")
core.register_alias("mapgen_river_water_source", "skelenti:water_source")
core.register_alias("mapgen_cobble", "skelenti:cobble")
core.register_biome({name = "grassland", node_top = "skelenti:grass",
	depth_top = 1, node_filler = "skelenti:dirt", depth_filler = 3,
	node_riverbed = "skelenti:sand", depth_riverbed = 2,
	y_min = 4, y_max = 31000, heat_point = 50, humidity_point = 50})
core.register_biome({name = "beach", node_top = "skelenti:sand",
	depth_top = 1, node_filler = "skelenti:sand", depth_filler = 2,
	node_riverbed = "skelenti:sand", depth_riverbed = 2,
	y_min = -6, y_max = 3, heat_point = 50, humidity_point = 50})
core.register_biome({name = "seabed", node_top = "skelenti:gravel",
	depth_top = 1, node_filler = "skelenti:sand", depth_filler = 2,
	y_min = -31000, y_max = -7, heat_point = 50, humidity_point = 50})
local function ore(name, scarcity, size, ymax, ymin)
	core.register_ore({ore_type = "scatter", ore = name,
		wherein = "skelenti:stone", clust_scarcity = scarcity,
		clust_num_ores = size, clust_size = 3, y_min = ymin or -31000,
		y_max = ymax})
end
ore("skelenti:coal_ore", 8 * 8 * 8, 8, 64)
ore("skelenti:iron_ore", 10 * 10 * 10, 5, 0)
ore("skelenti:diamond_ore", 15 * 15 * 15, 4, -48)
ore("skelenti:gravel", 16 * 16 * 16, 20, 64)
ore("skelenti:dirt", 16 * 16 * 16, 20, 64, -32)
do
	local t, l = {name = "skelenti:tree", force_place = true},
			{name = "skelenti:leaves"}
	local a = {name = "air", prob = 0}
	-- 5x6x5: a trunk of four, leaves around its top two and over it
	local data = {}
	for z = 0, 4 do for y = 0, 5 do for x = 0, 4 do
		local trunk = x == 2 and z == 2 and y < 4
		local edge = (x == 0 or x == 4) and (z == 0 or z == 4)
		local leaf = (y == 2 or y == 3) and not edge or
				y == 4 and x >= 1 and x <= 3 and z >= 1 and z <= 3 or
				y == 5 and (x == 2 or z == 2) and x >= 1 and x <= 3 and
				z >= 1 and z <= 3
		data[#data + 1] = trunk and t or leaf and l or a
	end end end
	core.register_decoration({deco_type = "schematic",
		place_on = {"skelenti:grass"}, sidelen = 16, fill_ratio = 0.006,
		biomes = {"grassland"}, y_min = 4, y_max = 200,
		schematic = {size = {x = 5, y = 6, z = 5}, data = data},
		flags = "place_center_x, place_center_z", rotation = "random"})
end

--
-- Players: the inventory the app draws, and drowning
--
core.register_on_joinplayer(function(player)
	local inv = player:get_inventory()
	inv:set_size("main", 36)
	inv:set_size("craft", 9)
	inv:set_width("craft", 3)
	inv:set_size("craftpreview", 1)
	inv:set_size("craftresult", 1)
	-- The app draws these (client_lua/ui.lua); the key opens its own
	-- inventory (client_lua/ui.lua)
	player:hud_set_flags({healthbar = false, breathbar = false,
		hotbar = false, crosshair = false, wielditem = true})
	player:hud_set_hotbar_itemcount(9)
	player:set_inventory_formspec("label[0,0;skelenti_inventory]")
end)

-- Drowning, which the module leaves to the game (its falls it does as
-- Luanti's client does): a breath a second under water, then a hit point
local breath_t = 0
core.register_globalstep(function(dtime)
	breath_t = breath_t + dtime
	if breath_t < 1 then
		return
	end
	breath_t = 0
	for _, p in ipairs(core.get_connected_players()) do
		local pos = p:get_pos()
		local head = core.get_node({x = pos.x, y = pos.y + 1.6,
				z = pos.z}).name
		local b = p:get_breath()
		if p:get_hp() == 0 then
			-- dead: nothing
		elseif core.get_item_group(head, "water") > 0 then
			if b > 0 then
				p:set_breath(b - 1)
			else
				p:set_hp(p:get_hp() - 1, {type = "drown"})
				core.log("action", "skelenti: " .. p:get_player_name() ..
						" drowns")
			end
		elseif b < 10 then
			p:set_breath(math.min(10, b + 2))
		end
	end
end)
dofile(core.get_modpath("skelenti") .. "/mobs.lua")
