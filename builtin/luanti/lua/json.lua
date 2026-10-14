-- Buildat: builtin/luanti/lua/json.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- core.parse_json and core.write_json, which in Luanti are jsoncpp behind a
-- pair of C functions. A mod uses them for anything that talks to the world
-- outside -- a server list, a mod's own data files.
--
-- What the two have to get right, and what devtest's unittests check: a
-- string may hold a null byte and it survives both ways, written as an
-- escape and read back; a whole number stays a whole number rather than
-- becoming 4.0e7; null is either dropped or the value the caller passed for
-- it; and a thousand levels of nesting come back.
--
-- simplified: no UTF-16 surrogate pairs on the way out -- a character above
-- the basic plane is written as the bytes it already is, which is valid
-- JSON as long as the input was UTF-8, and is what a mod's data files are.
-- On the way in, an escape is decoded to UTF-8, surrogate pairs included.

local function skip_space(s, i)
	local _, j = string.find(s, "^[ \t\r\n]*", i)
	return j + 1
end

-- One UTF-8 sequence of a code point, which is what an escape decodes to
local function utf8_char(cp)
	if cp < 0x80 then
		return string.char(cp)
	elseif cp < 0x800 then
		return string.char(0xc0 + math.floor(cp / 64), 0x80 + cp % 64)
	elseif cp < 0x10000 then
		return string.char(0xe0 + math.floor(cp / 4096),
				0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
	end
	return string.char(0xf0 + math.floor(cp / 262144),
			0x80 + math.floor(cp / 4096) % 64,
			0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
end

local ESCAPES = {
	['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f",
	n = "\n", r = "\r", t = "\t",
}

local parse_value

local function parse_string(s, i)
	-- i is at the opening quote
	local out = {}
	i = i + 1
	while true do
		local c = string.sub(s, i, i)
		if c == "" then
			return nil, i, "unterminated string"
		elseif c == '"' then
			return table.concat(out), i + 1
		elseif c == "\\" then
			local e = string.sub(s, i + 1, i + 1)
			if ESCAPES[e] then
				out[#out + 1] = ESCAPES[e]
				i = i + 2
			elseif e == "u" then
				local hex = string.sub(s, i + 2, i + 5)
				local cp = tonumber(hex, 16)
				if cp == nil or #hex < 4 then
					return nil, i, "bad unicode escape"
				end
				i = i + 6
				-- A pair of them is one character above the basic plane
				if cp >= 0xd800 and cp <= 0xdbff and
						string.sub(s, i, i + 1) == "\\u" then
					local low = tonumber(string.sub(s, i + 2, i + 5), 16)
					if low and low >= 0xdc00 and low <= 0xdfff then
						cp = 0x10000 + (cp - 0xd800) * 1024 + (low - 0xdc00)
						i = i + 6
					end
				end
				out[#out + 1] = utf8_char(cp)
			else
				return nil, i, "bad escape"
			end
		else
			out[#out + 1] = c
			i = i + 1
		end
	end
end

local function parse_number(s, i)
	local text = string.match(s, "^%-?%d+%.?%d*[eE]?[%+%-]?%d*", i)
	if text == nil or text == "" then
		return nil, i, "not a number"
	end
	local value = tonumber(text)
	if value == nil then
		return nil, i, "not a number"
	end
	return value, i + #text
end

-- nullvalue is what a JSON null becomes; nil means the key is simply absent,
-- which is Luanti's default and what a Lua table can say
parse_value = function(s, i, nullvalue)
	i = skip_space(s, i)
	local c = string.sub(s, i, i)
	if c == "" then
		return nil, i, "nothing there"
	elseif c == "{" then
		local out = {}
		i = skip_space(s, i + 1)
		if string.sub(s, i, i) == "}" then
			return out, i + 1
		end
		while true do
			i = skip_space(s, i)
			if string.sub(s, i, i) ~= '"' then
				return nil, i, "a key must be a string"
			end
			local key, err
			key, i, err = parse_string(s, i)
			if key == nil then
				return nil, i, err
			end
			i = skip_space(s, i)
			if string.sub(s, i, i) ~= ":" then
				return nil, i, "expected a colon"
			end
			local value
			value, i, err = parse_value(s, i + 1, nullvalue)
			if err then
				return nil, i, err
			end
			out[key] = value
			i = skip_space(s, i)
			local sep = string.sub(s, i, i)
			if sep == "," then
				i = i + 1
			elseif sep == "}" then
				return out, i + 1
			else
				return nil, i, "expected a comma or a brace"
			end
		end
	elseif c == "[" then
		local out = {}
		i = skip_space(s, i + 1)
		if string.sub(s, i, i) == "]" then
			return out, i + 1
		end
		while true do
			local value, err
			value, i, err = parse_value(s, i, nullvalue)
			if err then
				return nil, i, err
			end
			out[#out + 1] = value
			i = skip_space(s, i)
			local sep = string.sub(s, i, i)
			if sep == "," then
				i = i + 1
			elseif sep == "]" then
				return out, i + 1
			else
				return nil, i, "expected a comma or a bracket"
			end
		end
	elseif c == '"' then
		return parse_string(s, i)
	elseif string.sub(s, i, i + 3) == "true" then
		return true, i + 4
	elseif string.sub(s, i, i + 4) == "false" then
		return false, i + 5
	elseif string.sub(s, i, i + 3) == "null" then
		return nullvalue, i + 4
	end
	return parse_number(s, i)
end

-- Luanti: parse_json(string, nullvalue, return_error). Without return_error
-- a bad document is logged and nil comes back, which is what every caller
-- that does not ask is written for.
function core.parse_json(str, nullvalue, return_error)
	if type(str) ~= "string" then
		if return_error then
			return nil, "parse_json(): not a string"
		end
		core.log("error", "parse_json(): not a string")
		return nil
	end
	local value, i, err = parse_value(str, 1, nullvalue)
	if err == nil then
		i = skip_space(str, i)
		if i <= #str then
			err = "trailing data at " .. i
		end
	end
	if err then
		local message = "parse_json(): " .. err
		if return_error then
			return nil, message
		end
		core.log("error", message)
		return nil
	end
	return value
end

local STRING_ESCAPES = {
	['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
	["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}

local function write_string(value)
	return '"' .. string.gsub(value, "[%c\"\\]", function(c)
		return STRING_ESCAPES[c] or string.format("\\u%04x", string.byte(c))
	end) .. '"'
end

local function write_number(value)
	if value ~= value or value == math.huge or value == -math.huge then
		error("write_json(): " .. tostring(value) ..
				" is not a number JSON has")
	end
	-- A whole number stays one: %g would make 40048008 into 4.0048e+07
	if value == math.floor(value) and math.abs(value) < 2 ^ 53 then
		return string.format("%d", value)
	end
	return string.format("%.17g", value)
end

local write_value

write_value = function(value, out, indent, depth)
	local t = type(value)
	if value == nil then
		out[#out + 1] = "null"
	elseif t == "boolean" then
		out[#out + 1] = value and "true" or "false"
	elseif t == "number" then
		out[#out + 1] = write_number(value)
	elseif t == "string" then
		out[#out + 1] = write_string(value)
	elseif t == "table" then
		-- An array if its keys are 1..n and nothing else, which is the only
		-- thing a Lua table can say about which it is
		local n = 0
		local array = true
		for k, _ in pairs(value) do
			n = n + 1
			if type(k) ~= "number" then
				array = false
			end
		end
		if array then
			for i = 1, n do
				if value[i] == nil then
					array = false
					break
				end
			end
		end
		local pad, gap, nl = "", "", ""
		if indent then
			pad = string.rep("\t", depth + 1)
			gap = string.rep("\t", depth)
			nl = "\n"
		end
		if array then
			if n == 0 then
				out[#out + 1] = "[]"
				return
			end
			out[#out + 1] = "[" .. nl
			for i = 1, n do
				out[#out + 1] = pad
				write_value(value[i], out, indent, depth + 1)
				out[#out + 1] = (i < n and "," or "") .. nl
			end
			out[#out + 1] = gap .. "]"
		else
			local keys = {}
			for k, _ in pairs(value) do
				keys[#keys + 1] = k
			end
			table.sort(keys, function(a, b)
				return tostring(a) < tostring(b)
			end)
			if #keys == 0 then
				out[#out + 1] = "{}"
				return
			end
			out[#out + 1] = "{" .. nl
			for i, k in ipairs(keys) do
				out[#out + 1] = pad .. write_string(tostring(k)) ..
						(indent and " : " or ":")
				write_value(value[k], out, indent, depth + 1)
				out[#out + 1] = (i < #keys and "," or "") .. nl
			end
			out[#out + 1] = gap .. "}"
		end
	else
		error("write_json(): cannot write a " .. t)
	end
end

-- Luanti: write_json(data, styled). An error comes back rather than being
-- raised, which is what its own binding does.
function core.write_json(data, styled)
	local out = {}
	local ok, err = pcall(write_value, data, out, styled and true or nil, 0)
	if not ok then
		return nil, tostring(err)
	end
	return table.concat(out)
end

-- [LUANTI_APP_GLUE] The bridge to an app's C++: one call each way, a value
-- as JSON. call_json() on the module's interface is core.<name>(value)
-- here, its result written back ("null" for none); core.buildat_emit()
-- is the event "luanti:app:<name>" any module beside this one takes.
function core.__call_json(name, json)
	local f = core[name]
	if type(f) ~= "function" then
		error("core." .. tostring(name) .. " is not a function")
	end
	local r = f(core.parse_json(json))
	if r == nil then
		return "null"
	end
	return assert(core.write_json(r))
end

function core.buildat_emit(name, value)
	__luanti_emit(tostring(name), value == nil and "null" or
			assert(core.write_json(value)))
end

-- vim: set noet ts=4 sw=4:
