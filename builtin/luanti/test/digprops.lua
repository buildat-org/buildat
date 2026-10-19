-- SPDX-License-Identifier: Apache-2.0 OR MIT
-- Run by hand, by the command below; no runner references it.
-- Do the dig props carry what a dig needs?
--
--   BUILDAT_LUANTI_GAME=devtest BUILDAT_LUANTI_SAVE=digprops_check \
--   BUILDAT_LUANTI_LUA=builtin/luanti/test/digprops.lua \
--   bin/buildat_server -m ../apps/vanilla -D ../user
--
-- The client works a dig time out for itself out of core.__dig_props(), so
-- what has to hold is that its arithmetic on the records agrees with
-- core.get_dig_params() on the definitions they came from. This decodes the
-- records the way builtin/luanti/client_lua/module.lua does -- the parser
-- below is that one, and an edit belongs in both -- and compares every tool
-- the game registers against every node that has a group a tool rates.
--
-- It logs one line and aborts if any pair disagrees. No client is needed.

local function split_tab(s)
	local fields = {}
	for field in string.gmatch(s .. "\t", "([^\t]*)\t") do
		fields[#fields + 1] = field
	end
	return fields
end

local function decode(records)
	local items, nodes = {}, {}
	for _, record in ipairs(records) do
		local fields = split_tab(record)
		if fields[1] == "i" then
			local caps = nil
			if fields[5] ~= "" then
				caps = {
					full_punch_interval = tonumber(fields[5]) or 1,
					groupcaps = {},
				}
				for i = 6, #fields do
					local group, maxlevel, uses, times = string.match(
							fields[i], "^([^:]*):([^:]*):([^:]*):(.*)$")
					if group then
						local cap = {
							maxlevel = tonumber(maxlevel) or 1,
							uses = tonumber(uses) or 0,
							times = {},
						}
						for rating, time in
								string.gmatch(times, "([^=,]+)=([^,]+)") do
							cap.times[tonumber(rating)] = tonumber(time)
						end
						caps.groupcaps[group] = cap
					end
				end
			end
			items[fields[2]] = {
				range = tonumber(fields[3]) or -1,
				description = fields[4],
				caps = caps,
			}
		elseif fields[1] == "n" then
			local groups = {}
			for group, rating in
					string.gmatch(fields[3] or "", "([^=,]+)=([^,]+)") do
				groups[group] = tonumber(rating)
			end
			nodes[fields[2]] = groups
		end
	end
	return items, nodes
end

local function dig_time(caps, groups)
	if caps == nil or groups == nil then
		return nil
	end
	if not caps.groupcaps.dig_immediate then
		local immediate = groups.dig_immediate
		if immediate == 2 then
			return 0.5
		elseif immediate == 3 then
			return 0
		end
	end
	local level = groups.level or 0
	local best = nil
	for name, cap in pairs(caps.groupcaps) do
		local leveldiff = cap.maxlevel - level
		if leveldiff >= 0 then
			local rating = groups[name]
			local time = rating and cap.times[rating]
			if time then
				if leveldiff > 1 then
					time = time / leveldiff
				end
				if best == nil or time < best then
					best = time
				end
			end
		end
	end
	return best
end

core.register_on_mods_loaded(function()
	local items, nodes = decode(core.__dig_props())
	local n_items, n_nodes, n_pairs, n_bad = 0, 0, 0, 0
	for _ in pairs(items) do n_items = n_items + 1 end
	for _ in pairs(nodes) do n_nodes = n_nodes + 1 end
	assert(n_items > 0 and n_nodes > 0, "the records are empty")
	for item_name, props in pairs(items) do
		if props.caps then
			for node_name, groups in pairs(nodes) do
				local def = core.registered_nodes[node_name]
				local params = core.get_dig_params(def.groups,
						core.registered_items[item_name].tool_capabilities)
				local theirs = params.diggable and params.time or nil
				local ours = dig_time(props.caps, groups)
				n_pairs = n_pairs + 1
				-- The times cross as the text of a number, so they are the
				-- same number rather than a near one
				if ours ~= theirs then
					n_bad = n_bad + 1
					if n_bad <= 10 then
						core.log("error", "digprops: " .. item_name .. " on " ..
								node_name .. ": " .. tostring(ours) ..
								" rather than " .. tostring(theirs))
					end
				end
			end
		end
	end
	-- What the description is for is the slot tooltip, and an item with
	-- neither description nor short_description has an empty one
	local described = 0
	for _, props in pairs(items) do
		if props.description ~= "" then
			described = described + 1
		end
	end
	core.log("action", "digprops: " .. n_items .. " items (" .. described ..
			" described), " .. n_nodes .. " nodes with groups, " .. n_pairs ..
			" dig times, " .. n_bad .. " wrong")
	assert(n_bad == 0, "digprops: the client's dig time is not the server's")
end)
