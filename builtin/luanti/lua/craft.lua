-- Buildat: builtin/luanti/lua/craft.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- What a recipe makes. core.register_craft is Lua and records what a mod
-- wrote; this is the other half, which in Luanti is the C++ CraftDefManager:
-- given what is in a grid, which recipe it is and what comes out.
--
-- The five kinds Luanti has: shaped, which is a pattern that may sit
-- anywhere in the grid; shapeless, which is a multiset; cooking and fuel,
-- which are one item each; and toolrepair, which is two of the same worn
-- tool.
--
-- Both directions are indexed rather than walked: by what a recipe makes
-- (by_output) and by what goes into it (by_input). A game's craft guide asks
-- about every item it has, and VoxeLibre has four thousand of them.

local function alias_of(name)
	return core.__aliases[name] or name
end

-- A recipe's cell against a name from the grid. "group:a,b" wants all of
-- them, which is Luanti's rule and not an or.
local function cell_matches(spec, name)
	if spec == nil or spec == "" then
		return name == nil or name == ""
	end
	if name == nil or name == "" then
		return false
	end
	local groups = string.match(spec, "^group:(.*)$")
	if groups then
		for g in string.gmatch(groups, "[^,]+") do
			if core.get_item_group(name, g) == 0 then
				return false
			end
		end
		return true
	end
	return alias_of(spec) == alias_of(name)
end

-- Rows of cells, padded to the widest row
local function rows_to_grid(rows)
	local w = 0
	for _, row in ipairs(rows) do
		if type(row) ~= "table" then
			return nil
		end
		w = math.max(w, #row)
	end
	local grid = {}
	for y, row in ipairs(rows) do
		grid[y] = {}
		for x = 1, w do
			grid[y][x] = row[x] or ""
		end
	end
	return grid, w, #rows
end

-- The empty border is not part of the pattern: a recipe drawn in the middle
-- of a 3x3 and the same one in a corner are the same recipe
local function trim(grid)
	local y0, y1, x0, x1 = nil, nil, nil, nil
	for y = 1, #grid do
		for x = 1, #grid[y] do
			if grid[y][x] ~= "" then
				y0 = y0 or y
				y1 = y
				if x0 == nil or x < x0 then x0 = x end
				if x1 == nil or x > x1 then x1 = x end
			end
		end
	end
	if y0 == nil then
		return {}, 0, 0
	end
	local out = {}
	for y = y0, y1 do
		local row = {}
		for x = x0, x1 do
			row[#row + 1] = grid[y][x]
		end
		out[#out + 1] = row
	end
	return out, x1 - x0 + 1, y1 - y0 + 1
end

local function grids_match(recipe_grid, input_grid)
	if #recipe_grid ~= #input_grid then
		return false
	end
	for y = 1, #recipe_grid do
		if #recipe_grid[y] ~= #input_grid[y] then
			return false
		end
		for x = 1, #recipe_grid[y] do
			if not cell_matches(recipe_grid[y][x], input_grid[y][x]) then
				return false
			end
		end
	end
	return true
end

local function shapeless_match(specs, names)
	local left = {}
	for _, name in ipairs(names) do
		if name ~= "" then
			left[#left + 1] = name
		end
	end
	local wanted = {}
	for _, spec in ipairs(specs) do
		if spec ~= "" then
			wanted[#wanted + 1] = spec
		end
	end
	if #wanted ~= #left then
		return false
	end
	-- Greedy, and the plain names go first so that a group does not eat the
	-- item a name was going to match
	table.sort(wanted, function(a, b)
		return (string.match(a, "^group:") and 1 or 0) <
				(string.match(b, "^group:") and 1 or 0)
	end)
	for _, spec in ipairs(wanted) do
		local found = nil
		for i, name in ipairs(left) do
			if cell_matches(spec, name) then
				found = i
				break
			end
		end
		if found == nil then
			return false
		end
		table.remove(left, found)
	end
	return true
end

local function replacements_of(recipe)
	local out = {}
	for _, pair in ipairs(recipe.replacements or {}) do
		out[#out + 1] = ItemStack(pair[2])
	end
	return out
end

-- Luanti's own: what is left of two of the same tool is what is left of
-- each, plus the wear a repair costs
local function repair(a, b, additional_wear)
	local uses = (65536 - a:get_wear()) + (65536 - b:get_wear())
	local wear = 65536 - uses + math.floor((additional_wear or 0) * 65536 + 0.5)
	if wear >= 65536 then
		return nil
	end
	local out = ItemStack(a)
	out:set_wear(math.max(0, wear))
	return out
end

local function names_of(stacks)
	local names = {}
	for i, stack in ipairs(stacks) do
		names[i] = stack:is_empty() and "" or stack:get_name()
	end
	return names
end

local function try_recipe(recipe, method, stacks, names, width)
	local kind = recipe.type or "shaped"
	if kind == "cooking" or kind == "fuel" then
		if method ~= kind then
			return nil
		end
		local n = 0
		local one = nil
		for _, name in ipairs(names) do
			if name ~= "" then
				n = n + 1
				one = name
			end
		end
		if n ~= 1 or not cell_matches(recipe.recipe, one) then
			return nil
		end
		if kind == "cooking" then
			return {item = ItemStack(recipe.output),
					time = recipe.cooktime or 3,
					replacements = replacements_of(recipe)}
		end
		return {item = ItemStack(""), time = recipe.burntime or 1,
				replacements = replacements_of(recipe)}
	end
	if method ~= "normal" then
		return nil
	end
	if kind == "toolrepair" then
		local worn = {}
		for _, stack in ipairs(stacks) do
			if not stack:is_empty() then
				worn[#worn + 1] = stack
			end
		end
		if #worn ~= 2 or worn[1]:get_name() ~= worn[2]:get_name() then
			return nil
		end
		local def = core.registered_items[worn[1]:get_name()]
		if def == nil or def.type ~= "tool" then
			return nil
		end
		-- A tool can say it is not repairable, and then it is not
		if core.get_item_group(worn[1]:get_name(), "disable_repair") ~= 0 then
			return nil
		end
		local out = repair(worn[1], worn[2], recipe.additional_wear)
		if out == nil then
			return nil
		end
		return {item = out, time = 0, replacements = {}}
	end
	if kind == "shapeless" then
		if not shapeless_match(recipe.recipe or {}, names) then
			return nil
		end
		return {item = ItemStack(recipe.output), time = 0,
				replacements = replacements_of(recipe)}
	end
	if kind ~= "shaped" then
		return nil
	end
	local grid = rows_to_grid(recipe.recipe or {})
	if grid == nil then
		return nil
	end
	local input = {}
	for y = 1, math.ceil(#names / width) do
		input[y] = {}
		for x = 1, width do
			input[y][x] = names[(y - 1) * width + x] or ""
		end
	end
	if not grids_match((trim(grid)), (trim(input))) then
		return nil
	end
	return {item = ItemStack(recipe.output), time = 0,
			replacements = replacements_of(recipe)}
end

-- Recipes by what goes into them, which is what makes crafting a lookup
-- rather than a walk over every recipe in the game. Luanti's own
-- craftdef.cpp keys them three ways and tries the keys in turn; these are
-- the two that matter here:
--
--   by_input[method .. "\1" .. the recipe's distinct item names, sorted]
--       for a recipe made of concrete items, which is most of them
--   by_count[method .. "\1" .. how many cells it fills]
--       for the rest, because a group spec matches names the recipe itself
--       does not contain, and a count is the most that can be said about it
--
-- A lookup asks both and try_recipe() decides exactly as it did before; what
-- changed is how many recipes it is asked about. The two lists are merged by
-- the order the recipes were registered in, because the first match wins and
-- that has to be the same recipe it was before.
local by_input = nil
local by_count = nil

-- What a recipe wants, as (method, the distinct names it names or nil if any
-- of it is a group, how many cells it fills). nil for a kind this does not
-- know, which is then always tried.
local function recipe_inputs(recipe)
	local kind = recipe.type or "shaped"
	local method = (kind == "cooking" or kind == "fuel") and kind or "normal"
	local names, count, grouped = {}, 0, false
	local function cell(spec)
		if spec == nil or spec == "" then
			return
		end
		count = count + 1
		if string.match(spec, "^group:") then
			grouped = true
		else
			names[#names + 1] = alias_of(spec)
		end
	end
	if kind == "cooking" or kind == "fuel" then
		cell(recipe.recipe)
	elseif kind == "shapeless" then
		local specs = recipe.recipe or {}
		for i = 1, #specs do
			cell(specs[i])
		end
	elseif kind == "toolrepair" then
		-- Two worn tools of a kind the recipe does not name: there is
		-- nothing to key on but the count
		count, grouped = 2, true
	elseif kind == "shaped" then
		local rows = recipe.recipe or {}
		for y = 1, #rows do
			local row = rows[y]
			if type(row) ~= "table" then
				return nil
			end
			-- Not ipairs: a row written with a hole in it ends one early,
			-- and a cell is "" rather than nil in every recipe that has one
			for x = 1, #row do
				cell(row[x])
			end
		end
	else
		return nil
	end
	return method, (not grouped) and names or nil, count
end

local function names_key(method, names)
	table.sort(names)
	local distinct = {}
	for i = 1, #names do
		if names[i] ~= names[i - 1] then
			distinct[#distinct + 1] = names[i]
		end
	end
	return method .. "\1" .. table.concat(distinct, "\1")
end

local function input_index()
	if by_input ~= nil then
		return by_input, by_count
	end
	by_input, by_count = {}, {}
	local function add(into, key, i, recipe)
		local list = into[key]
		if list == nil then
			list = {}
			into[key] = list
		end
		list[#list + 1] = {i = i, r = recipe}
	end
	for i, recipe in ipairs(core.__crafts) do
		local method, names, count = recipe_inputs(recipe)
		if method == nil then
			-- Not a kind this knows: it goes in every count's list rather
			-- than being lost. There are none in any game here; this is so
			-- that a new kind is slow rather than silently missing.
			for n = 0, 9 do
				add(by_count, "normal\1" .. n, i, recipe)
			end
		elseif names ~= nil then
			add(by_input, names_key(method, names), i, recipe)
		else
			add(by_count, method .. "\1" .. count, i, recipe)
		end
	end
	return by_input, by_count
end

-- The recipes worth trying for what is in the grid, in the order they were
-- registered: the two lists are each in that order already, so this is one
-- merge rather than a sort.
local function candidates(method, names)
	local index, counts = input_index()
	local concrete = {}
	local n = 0
	for i = 1, #names do
		if names[i] ~= "" then
			n = n + 1
			concrete[n] = alias_of(names[i])
		end
	end
	local a = index[names_key(method, concrete)] or {}
	local b = counts[method .. "\1" .. n] or {}
	if #a == 0 then
		return b
	end
	if #b == 0 then
		return a
	end
	local out, ai, bi = {}, 1, 1
	while ai <= #a or bi <= #b do
		if bi > #b or (ai <= #a and a[ai].i < b[bi].i) then
			out[#out + 1] = a[ai]
			ai = ai + 1
		else
			out[#out + 1] = b[bi]
			bi = bi + 1
		end
	end
	return out
end

-- The index says what the walk it replaced said: every registered recipe is
-- among the candidates for its own inputs. Checked at a start under
-- BUILDAT_LUANTI_SELFCHECKS=1 (the checks), because a key built one way here
-- and another way there is a recipe that quietly stops working, and a game
-- has thousands of them.
function core.__check_craft_index()
	local checked = 0
	for i, recipe in ipairs(core.__crafts) do
		local method, names, count = recipe_inputs(recipe)
		if method ~= nil then
			local grid = names
			if grid == nil then
				-- One with a group in it is keyed by how many cells it
				-- fills, so any names of that many will do
				grid = {}
				for n = 1, count do
					grid[n] = "__check_craft"
				end
			end
			if #grid > 0 then
				local found = false
				for _, entry in ipairs(candidates(method, grid)) do
					if entry.r == recipe then
						found = true
						break
					end
				end
				assert(found, "check_craft_index: recipe " .. i .. " (" ..
						tostring(recipe.output) ..
						") is not among the candidates for its own inputs")
				checked = checked + 1
			end
		end
	end
	core.log("verbose", "check_craft_index: " .. checked ..
			" recipes are found by what goes into them")
end

local EMPTY = function(method, width, stacks)
	return {item = ItemStack(""), time = 0, replacements = {}},
			{method = method, width = width, items = stacks}
end

function core.get_craft_result(input)
	input = input or {}
	local method = input.method or "normal"
	local width = input.width or 3
	if width < 1 then
		width = 1
	end
	local stacks = {}
	for i, item in ipairs(input.items or {}) do
		stacks[i] = ItemStack(item)
	end
	local names = names_of(stacks)
	for _, entry in ipairs(candidates(method, names)) do
		local out = try_recipe(entry.r, method, stacks, names, width)
		if out then
			-- One of each is what a craft takes, whatever the method
			local left = {}
			for i, stack in ipairs(stacks) do
				local s = ItemStack(stack)
				if not s:is_empty() then
					s:take_item(1)
				end
				left[i] = s
			end
			return out, {method = method, width = width, items = left}
		end
	end
	return EMPTY(method, width, stacks)
end

-- What a recipe looks like from the other end: given an output, the items
-- that make it. Luanti answers with the last registered one, and with a
-- width of 0 for anything that is not shaped.
-- What a recipe's cell is called from the outside: the name it points at,
-- since an alias is resolved when a recipe is registered and everything
-- asking about one asks about the real item
local function spec_name(spec)
	if spec == nil or spec == "" or string.match(spec, "^group:") then
		return spec
	end
	return alias_of(spec)
end

-- The pairs of item names a recipe swaps out, as Luanti hands them back
local function replacement_pairs(recipe)
	local out = {}
	for _, pair in ipairs(recipe.replacements or {}) do
		out[#out + 1] = {spec_name(pair[1]), spec_name(pair[2])}
	end
	if #out == 0 then
		return nil
	end
	return out
end

-- What Luanti answers with: the method it is crafted by -- "normal" for both
-- of the grid kinds -- and the time only where there is one
local function recipe_to_table(recipe)
	local kind = recipe.type or "shaped"
	if kind == "shaped" or kind == "shapeless" then
		local items = {}
		local w = 0
		if kind == "shaped" then
			local grid
			grid, w = rows_to_grid(recipe.recipe or {})
			if grid then
				-- An empty cell is left out and the rest keep their
				-- places, as Luanti's push_items(): a "" in the table is
				-- an item nobody has, and VoxeLibre's recipe book hid
				-- every recipe with a gap in it ([VL_INV_PARITY])
				for y = 1, #grid do
					for x = 1, w do
						local name = spec_name(grid[y][x])
						if name ~= "" then
							items[(y - 1) * w + x] = name
						end
					end
				end
			end
		else
			for i, spec in ipairs(recipe.recipe or {}) do
				local name = spec_name(spec)
				if name ~= "" then
					items[i] = name
				end
			end
		end
		return {method = "normal", width = w or 0, items = items,
				output = recipe.output, type = "normal",
				replacements = replacement_pairs(recipe)}
	end
	return {method = kind, width = 0, items = {spec_name(recipe.recipe)},
			output = recipe.output or "", type = kind,
			replacements = replacement_pairs(recipe),
			time = kind == "cooking" and (recipe.cooktime or 3) or
					(recipe.burntime or 1)}
end

local function output_matches(recipe, wanted)
	local want = ItemStack(wanted)
	-- A fuel recipe makes nothing, so nothing is what it is looked up by
	if want:is_empty() then
		return (recipe.type or "shaped") == "fuel"
	end
	if recipe.output == nil then
		return false
	end
	local out = ItemStack(recipe.output)
	if out:is_empty() then
		return false
	end
	return alias_of(out:get_name()) == alias_of(want:get_name())
end

-- Which recipes make what, built the first time something asks and dropped
-- whenever a recipe or an alias changes.
--
-- VoxeLibre's craft guide asks get_all_craft_recipes() about every one of
-- its four thousand items while it loads, and a walk of every recipe for
-- each of those -- with two ItemStacks built per recipe to compare two
-- names -- was two thirds of a two-minute startup: 27% of the Lua in
-- parse_itemstring() alone. This is the lookup half of the "no crafting
-- hash and no cache" note at the top of this file; crafting itself still
-- walks.
local by_output = nil

-- What a recipe makes, as the name a lookup would ask for, or nil for one
-- that is not looked up by name at all. An alias is resolved twice because
-- ItemStack resolves one on the way in and the comparison resolved another;
-- a chain of two is what that came to and this keeps it.
local function output_key(recipe)
	local out = recipe.output
	if out == nil then
		return nil
	end
	local name = string.match(tostring(out), "^[^ ]*") or ""
	if name == "" then
		return nil
	end
	return alias_of(alias_of(name))
end

local function output_index()
	if by_output ~= nil then
		return by_output
	end
	by_output = {}
	local function add(key, recipe)
		local list = by_output[key]
		if list == nil then
			list = {}
			by_output[key] = list
		end
		list[#list + 1] = recipe
	end
	for _, recipe in ipairs(core.__crafts) do
		-- A fuel recipe makes nothing, so nothing is what it is looked up
		-- by -- and one that also names an output is found by that as well,
		-- which is what the walk this replaces did
		if (recipe.type or "shaped") == "fuel" then
			add("", recipe)
		end
		local key = output_key(recipe)
		if key ~= nil then
			add(key, recipe)
		end
	end
	return by_output
end

-- Called wherever the recipes or the aliases change; see register_craft()
-- and register_alias_raw() in bootstrap.lua
function core.__forget_craft_index()
	by_output = nil
	by_input = nil
	by_count = nil
end

-- The recipes that make one thing, in the order they were registered
local function recipes_making(output)
	local want = ItemStack(output)
	local key = want:is_empty() and "" or alias_of(want:get_name())
	return output_index()[key] or {}
end

function core.get_craft_recipe(output)
	local list = recipes_making(output)
	-- The last one registered, which is what walking the whole list and
	-- keeping the last hit came to
	local found = list[#list]
	if found == nil then
		return {method = "normal", width = 0, items = {}}
	end
	return recipe_to_table(found)
end

function core.get_all_craft_recipes(output)
	local all = {}
	for _, recipe in ipairs(recipes_making(output)) do
		all[#all + 1] = recipe_to_table(recipe)
	end
	if #all == 0 then
		return nil
	end
	return all
end

-- Luanti takes either an output or a recipe here, and answers with whether
-- it removed anything
function core.clear_craft(spec)
	if type(spec) ~= "table" then
		error("clear_craft(): needs a table")
	end
	local removed = false
	for i = #core.__crafts, 1, -1 do
		local recipe = core.__crafts[i]
		local hit = false
		if spec.output then
			hit = output_matches(recipe, spec.output)
		elseif spec.recipe then
			local names = {}
			local rows = spec.recipe
			if type(rows[1]) == "table" then
				local grid, w, h = rows_to_grid(rows)
				for y = 1, h do
					for x = 1, w do
						names[(y - 1) * w + x] = grid[y][x]
					end
				end
				hit = try_recipe(recipe, "normal", {}, names, w) ~= nil
			else
				for k, v in ipairs(rows) do
					names[k] = v
				end
				hit = try_recipe(recipe, "normal", {}, names, #names) ~= nil
			end
		end
		if hit then
			table.remove(core.__crafts, i)
			removed = true
		end
	end
	if removed then
		core.__forget_craft_index()
	end
	return removed
end

-- vim: set noet ts=4 sw=4:
