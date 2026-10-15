-- Buildat: extension/network/csv.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- Minimal CSV, for extension/network's address store. See test_csv.lua.

local M = {}

function M.quote(field)
	return '"'..tostring(field):gsub('"', '""')..'"'
end

function M.parse_line(line)
	local fields = {}
	local i = 1
	while true do
		local field
		if line:sub(i, i) == '"' then
			local parts = {}
			i = i + 1
			while true do
				local j = line:find('"', i, true)
				if not j then -- Unterminated quote; take the rest
					table.insert(parts, line:sub(i))
					i = #line + 1
					break
				end
				table.insert(parts, line:sub(i, j - 1))
				if line:sub(j + 1, j + 1) == '"' then
					table.insert(parts, '"')
					i = j + 2
				else
					i = j + 1
					break
				end
			end
			field = table.concat(parts)
		else
			local j = line:find(",", i, true) or (#line + 1)
			field = line:sub(i, j - 1)
			i = j
		end
		table.insert(fields, field)
		if line:sub(i, i) ~= "," then
			break
		end
		i = i + 1
	end
	return fields
end

return M
-- vim: set noet ts=4 sw=4:
