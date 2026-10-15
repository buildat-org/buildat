-- Buildat: extension/network/test_csv.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- Run: lua client/core/network/test_csv.lua

local csv = dofile((arg[0]:match("^(.*)/[^/]*$") or ".").."/csv.lua")

local function check_roundtrip(fields)
	local line = {}
	for _, f in ipairs(fields) do
		table.insert(line, csv.quote(f))
	end
	local parsed = csv.parse_line(table.concat(line, ","))
	assert(#parsed == #fields, "field count: "..#parsed.." vs "..#fields)
	for i, f in ipairs(fields) do
		assert(parsed[i] == f, "field "..i..": "..parsed[i].." vs "..f)
	end
end

check_roundtrip({"true", "udp://127.0.0.1:30000", "Test server", "1757000000", "0"})
check_roundtrip({"false", "tcp://example.com:80", 'a "quoted", comma-y one', "1", "2"})
check_roundtrip({"", "", "", "", ""})

-- Unquoted fields, as a hand-edited file may have them
local f = csv.parse_line('true,udp://127.0.0.1:30000,My server,1,2')
assert(f[1] == "true" and f[3] == "My server" and f[5] == "2", "unquoted fields")

-- Mixed, and a trailing empty field
f = csv.parse_line('true,"desc",')
assert(#f == 3 and f[2] == "desc" and f[3] == "", "trailing empty field")

-- Unterminated quote: take what is there instead of erroring
f = csv.parse_line('"unterminated')
assert(f[1] == "unterminated", "unterminated quote")

print("test_csv.lua: ok")
